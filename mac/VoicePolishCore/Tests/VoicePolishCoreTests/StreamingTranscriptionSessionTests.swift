import XCTest
@testable import VoicePolishCore

final class StreamingTranscriptionSessionTests: XCTestCase {

    private let sampleRate = 16000
    private var seed: UInt64 = 12345

    private func rnd() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
    }
    /// 带 3Hz 音节起伏的合成语音（更接近真实：帧能量有高低，P10 能落到"安静音节"上）
    private func speech(_ sec: Double) -> [Float] {
        (0..<Int(sec * Double(sampleRate))).map { i -> Float in
            let t = Float(i) / Float(sampleRate)
            let env = 0.1 + 0.25 * abs(sin(2 * .pi * 3 * t))  // 0.1~0.35 起伏，不归零
            return env * sin(2 * .pi * 440 * t) + 0.01 * rnd()
        }
    }
    private func silence(_ sec: Double) -> [Float] {
        (0..<Int(sec * Double(sampleRate))).map { _ in 0.01 * rnd() }
    }
    /// N 段「说话+停顿」，返回样本
    private func speechWithPauses(blocks: Int, speechSec: Double = 5.6, gapSec: Double = 0.4) -> [Float] {
        var s: [Float] = []
        for _ in 0..<blocks { s += speech(speechSec); s += silence(gapSec) }
        return s
    }

    /// 驱动一次 ingest，等提交处理完；返回是否真的提交了（不再有可提交段时返回 false，不失败）
    @discardableResult
    private func ingestOnce(_ session: StreamingTranscriptionSession, _ snapshot: [Float]) -> Bool {
        let exp = expectation(description: "commit")
        session.onCommitProcessed = { _ in exp.fulfill() }
        session.ingest(snapshot: snapshot)
        let result = XCTWaiter().wait(for: [exp], timeout: 0.4)
        session.onCommitProcessed = nil
        return result == .completed
    }

    /// 反复 ingest 直到不再产生新提交
    private func drainCommits(_ session: StreamingTranscriptionSession, _ snapshot: [Float], max: Int = 10) {
        for _ in 0..<max where ingestOnce(session, snapshot) {}
    }

    // MARK: - 录音中提交 + 顺序拼接

    func testStreamingCommitsThenTailInOrder() {
        var commitCount = 0
        let lock = NSLock()
        let session = StreamingTranscriptionSession(chunkTranscriber: { _, done in
            lock.lock(); commitCount += 1; lock.unlock()
            DispatchQueue.global().async { done(.success("C")) }
        }, tailTranscriber: { _, done in
            DispatchQueue.global().async { done(.success("尾")) }
        })

        let snapshot = speechWithPauses(blocks: 6)  // ~36s，多处停顿
        drainCommits(session, snapshot)
        XCTAssertGreaterThan(commitCount, 1, "录音中应至少提交 2 段")
        XCTAssertGreaterThan(session.committedIndexForTest, 0)

        let exp = expectation(description: "finish")
        session.finish(finalSamples: snapshot) { result in
            guard case .success(let text) = result else { return XCTFail("should succeed") }
            // 结果 = 若干个 "C" + "尾"，顺序正确
            XCTAssertTrue(text.hasSuffix("尾"))
            XCTAssertEqual(text, String(repeating: "C", count: text.count - 1) + "尾")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
    }

    // MARK: - 连续说话无停顿 → 不提交，退化为整段(仅尾巴)

    func testNoPauseFallsBackToTailOnly() {
        var commitCount = 0
        let lock = NSLock()
        let session = StreamingTranscriptionSession(chunkTranscriber: { _, done in
            lock.lock(); commitCount += 1; lock.unlock()
            DispatchQueue.global().async { done(.success("X")) }
        }, tailTranscriber: { _, done in
            DispatchQueue.global().async { done(.success("整段")) }
        })
        let snapshot = speech(16)  // 连续说话，无 220ms 停顿 → 不应提交
        drainCommits(session, snapshot)
        XCTAssertEqual(commitCount, 0, "无停顿不应提交")

        let exp = expectation(description: "finish")
        session.finish(finalSamples: snapshot) { result in
            guard case .success(let text) = result else { return XCTFail() }
            XCTAssertEqual(text, "整段")  // 未提交 → 尾巴=整段
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
    }

    // MARK: - 空段前向合并：某段识别为空 → 不推进，音频并入后续，不丢内容

    func testEmptyCommitMergesForward() {
        var callIndex = 0
        let lock = NSLock()
        var committedStartsAtZeroAgain = false
        let session = StreamingTranscriptionSession(chunkTranscriber: { _, done in
            lock.lock(); callIndex += 1; let n = callIndex; lock.unlock()
            // 第一段返回空 → 应触发前向合并（提交位置不前进）
            DispatchQueue.global().async { done(.success(n == 1 ? "" : "有")) }
        }, tailTranscriber: { _, done in
            DispatchQueue.global().async { done(.success("尾")) }
        })
        let snapshot = speechWithPauses(blocks: 6)

        // 第一次提交（返回空）
        XCTAssertTrue(ingestOnce(session, snapshot))
        XCTAssertEqual(session.committedIndexForTest, 0, "空段不应推进提交位置")
        committedStartsAtZeroAgain = (session.committedIndexForTest == 0)
        XCTAssertTrue(committedStartsAtZeroAgain)

        // 后续提交（有内容）→ 应越过之前的空切点、包含那段音频
        drainCommits(session, snapshot)
        XCTAssertGreaterThan(session.committedIndexForTest, 0, "后续应成功提交并前进")

        let exp = expectation(description: "finish")
        session.finish(finalSamples: snapshot) { result in
            guard case .success(let text) = result else { return XCTFail() }
            XCTAssertTrue(text.contains("有") && text.hasSuffix("尾"))
            XCTAssertFalse(text.isEmpty)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
    }

    // MARK: - finish 等在途段完成后再收尾

    func testFinishWaitsForInFlightCommit() {
        let commitStarted = expectation(description: "commit started")
        var releaseCommit: (() -> Void)?
        let session = StreamingTranscriptionSession(chunkTranscriber: { _, done in
            commitStarted.fulfill()
            releaseCommit = { done(.success("C")) }  // 手动控制何时完成
        }, tailTranscriber: { _, done in
            DispatchQueue.global().async { done(.success("尾")) }
        })
        let snapshot = speechWithPauses(blocks: 6)
        session.ingest(snapshot: snapshot)
        wait(for: [commitStarted], timeout: 3)  // 一段在途、未完成

        let finished = expectation(description: "finished")
        var finishReturnedEarly = true
        session.finish(finalSamples: snapshot) { result in
            finishReturnedEarly = false
            guard case .success(let text) = result else { return XCTFail() }
            XCTAssertEqual(text, "C尾")  // 在途段先入，再接尾巴
            finished.fulfill()
        }
        // 在途段还没放行，finish 不应先返回
        XCTAssertTrue(finishReturnedEarly)
        releaseCommit?()  // 放行在途段 → 触发收尾
        wait(for: [finished], timeout: 3)
    }

    // MARK: - 尾巴失败：不能静默丢句尾

    private func finishResult(tail: Result<String, Error>) -> Result<String, Error>? {
        let session = StreamingTranscriptionSession(chunkTranscriber: { _, done in
            DispatchQueue.global().async { done(.success("C")) }
        }, tailTranscriber: { _, done in
            DispatchQueue.global().async { done(tail) }
        })
        let snapshot = speechWithPauses(blocks: 6)
        drainCommits(session, snapshot)
        XCTAssertGreaterThan(session.committedIndexForTest, 0, "前提：已有提交段")
        let exp = expectation(description: "finish")
        var out: Result<String, Error>?
        session.finish(finalSamples: snapshot) { out = $0; exp.fulfill() }
        wait(for: [exp], timeout: 3)
        return out
    }

    func testTailFailureReportsErrorInsteadOfDroppingTail() {
        let result = finishResult(tail: .failure(CloudASRTranscriber.TranscriptionError.timeout))
        guard case .failure = result else { return XCTFail("尾巴识别失败应上报错误，让上层整段重识别") }
    }

    func testTailNoSpeechKeepsCommittedText() {
        let result = finishResult(tail: .failure(CloudASRTranscriber.TranscriptionError.noSpeech))
        guard case .success(let text) = result else { return XCTFail("尾巴无语音应返回已提交文字") }
        XCTAssertFalse(text.isEmpty)
    }
}

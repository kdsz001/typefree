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
        // 「提交了」和「这次没东西可提交」各有一个钩子，哪个先响就是哪个结果——不靠超时判定。
        // 原先用 0.4s 超时当「没提交」的判据：慢机器（CI）上可能把一次真提交判成没提交，
        // drainCommits 提前收手、后面的断言跟着失败；单纯把超时放宽又会让整套测试从 12s 变 46s。
        let settled = expectation(description: "ingest settled")
        settled.assertForOverFulfill = false
        var didCommit = false
        session.onCommitProcessed = { _ in didCommit = true; settled.fulfill() }
        session.onIngestIdle = { settled.fulfill() }
        session.ingest(snapshot: snapshot)
        let outcome = XCTWaiter().wait(for: [settled], timeout: 5)
        session.onCommitProcessed = nil
        session.onIngestIdle = nil
        XCTAssertEqual(outcome, .completed, "ingest 既没提交也没报空闲，说明卡住了")
        return didCommit
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

    // MARK: - 尾巴识别失败（工单 #1024 同类：以前悄悄只给前半段，后半截话凭空消失）

    private struct FakeError: Error {}

    /// 尾巴第一次失败、第二次成功 → 照常拼全文
    func testTailFailureRetriesOnce() {
        var tailCalls = 0
        let lock = NSLock()
        let session = StreamingTranscriptionSession(chunkTranscriber: { _, done in
            DispatchQueue.global().async { done(.success("C")) }
        }, tailTranscriber: { _, done in
            lock.lock(); tailCalls += 1; let n = tailCalls; lock.unlock()
            DispatchQueue.global().async { done(n == 1 ? .failure(FakeError()) : .success("尾")) }
        })
        let snapshot = speechWithPauses(blocks: 6)
        drainCommits(session, snapshot)
        let exp = expectation(description: "finish")
        session.finish(finalSamples: snapshot) { result in
            guard case .success(let text) = result else { return XCTFail("重试后应成功") }
            XCTAssertTrue(text.hasSuffix("尾"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
        XCTAssertEqual(tailCalls, 2)
    }

    /// 尾巴两次都失败、前面已有文字 → 不再悄悄当成功，交出前半段让上层提醒
    func testTailFailsTwiceReturnsPartialError() {
        let session = StreamingTranscriptionSession(chunkTranscriber: { _, done in
            DispatchQueue.global().async { done(.success("C")) }
        }, tailTranscriber: { _, done in
            DispatchQueue.global().async { done(.failure(FakeError())) }
        })
        let snapshot = speechWithPauses(blocks: 6)
        drainCommits(session, snapshot)
        XCTAssertFalse(session.committedText.isEmpty)
        let exp = expectation(description: "finish")
        session.finish(finalSamples: snapshot) { result in
            guard case .failure(let error) = result,
                  let partial = error as? StreamingTranscriptionSession.PartialResultError else {
                return XCTFail("应返回 PartialResultError")
            }
            XCTAssertFalse(partial.text.isEmpty)
            XCTAssertEqual(partial.text, String(repeating: "C", count: partial.text.count))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
    }

    /// 前面什么都没识别出来时尾巴失败 → 直接报错，不重试（调用方会整段重识别）
    func testTailFailureWithoutCommitReportsError() {
        var tailCalls = 0
        let lock = NSLock()
        let session = StreamingTranscriptionSession(chunkTranscriber: { _, done in
            DispatchQueue.global().async { done(.success("C")) }
        }, tailTranscriber: { _, done in
            lock.lock(); tailCalls += 1; lock.unlock()
            DispatchQueue.global().async { done(.failure(FakeError())) }
        })
        let exp = expectation(description: "finish")
        session.finish(finalSamples: speech(5)) { result in
            guard case .failure(let error) = result else { return XCTFail("应失败") }
            XCTAssertFalse(error is StreamingTranscriptionSession.PartialResultError)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
        XCTAssertEqual(tailCalls, 1)
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

    // MARK: - 空/无语音/失败仅补救一次，仍失败则保留音频等松手

    func testEmptyCommitRetriesOnceThenWaitsForFinishAndPreservesAudio() {
        var commitCalls = 0
        var tailCalls = 0
        var tailSamples: [Float] = []
        let session = StreamingTranscriptionSession(chunkTranscriber: { _, done in
            commitCalls += 1
            done(.success(" \n"))
        }, tailTranscriber: { samples, done in
            tailCalls += 1
            tailSamples = samples
            done(.success("恢复的完整内容"))
        })
        let finalSamples = speechWithPauses(blocks: 6)
        XCTAssertTrue(ingestOnce(session, Array(finalSamples.prefix(18 * sampleRate))))
        XCTAssertEqual(session.committedIndexForTest, 0, "空结果不能直接丢掉音频")
        XCTAssertTrue(ingestOnce(session, Array(finalSamples.prefix(20 * sampleRate))),
                      "首次空结果可带上后续音频再补救一次")
        for seconds in stride(from: 22, through: 36, by: 2) {
            XCTAssertFalse(ingestOnce(session, Array(finalSamples.prefix(seconds * sampleRate))),
                           "连续两次空结果后应等松手，不能随录音增长反复上传旧音频")
        }
        XCTAssertEqual(commitCalls, 2)

        let exp = expectation(description: "finish")
        session.finish(finalSamples: finalSamples) { result in
            guard case .success(let text) = result else { return XCTFail() }
            XCTAssertEqual(text, "恢复的完整内容")
            XCTAssertEqual(tailSamples, finalSamples, "松手后仍须包含此前误判为空的音频")
            XCTAssertEqual(tailCalls, 1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
    }

    /// 回归 2026-10-07：每 2 秒取一次越来越长的快照，服务器持续返回无语音。
    /// 旧逻辑反复上传同一前缀，把几分钟录音累加成两小时会员用量。
    func testNoSpeechOnGrowingRecordingStopsRepeatedUploads() {
        var commitCalls = 0
        var uploadedSamples = 0
        let session = StreamingTranscriptionSession(chunkTranscriber: { samples, done in
            commitCalls += 1
            uploadedSamples += samples.count
            done(.failure(CloudASRTranscriber.TranscriptionError.noSpeech))
        }, tailTranscriber: { samples, done in
            uploadedSamples += samples.count
            done(.success("松手后恢复"))
        })
        let finalSamples = speechWithPauses(blocks: 20) // 120 秒，带停顿以触发录音中提交
        for seconds in stride(from: 8, through: 120, by: 2) {
            ingestOnce(session, Array(finalSamples.prefix(seconds * sampleRate)))
        }
        XCTAssertEqual(commitCalls, 2, "连续两次无语音后不能每两秒重新识别越来越长的旧音频")
        XCTAssertEqual(session.committedIndexForTest, 0)

        let exp = expectation(description: "finish")
        session.finish(finalSamples: finalSamples) { result in
            guard case .success(let text) = result else { return XCTFail() }
            XCTAssertEqual(text, "松手后恢复")
            XCTAssertLessThanOrEqual(uploadedSamples, finalSamples.count + 24 * self.sampleRate,
                                    "总上传量应限于首次短段、一次补救与松手后的完整录音")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
    }

    func testFailedCommitPreservesPendingAudioAndCommittedText() {
        var commitCalls = 0
        var tailSamples: [Float] = []
        let session = StreamingTranscriptionSession(chunkTranscriber: { _, done in
            commitCalls += 1
            done(commitCalls == 1 ? .success("前半段") : .failure(FakeError()))
        }, tailTranscriber: { samples, done in
            tailSamples = samples
            done(.success("后半段"))
        })
        let finalSamples = speechWithPauses(blocks: 6)
        XCTAssertTrue(ingestOnce(session, finalSamples))
        let committedIndex = session.committedIndexForTest
        XCTAssertGreaterThan(committedIndex, 0)
        XCTAssertTrue(ingestOnce(session, finalSamples))
        XCTAssertTrue(ingestOnce(session, finalSamples), "首次失败后允许补救一次")
        XCTAssertFalse(ingestOnce(session, finalSamples), "补救仍失败后应暂停录音中提交")
        XCTAssertEqual(commitCalls, 3)
        XCTAssertEqual(session.committedIndexForTest, committedIndex)

        let exp = expectation(description: "finish")
        session.finish(finalSamples: finalSamples) { result in
            guard case .success(let text) = result else { return XCTFail() }
            XCTAssertEqual(text, "前半段后半段")
            XCTAssertEqual(tailSamples, Array(finalSamples[committedIndex...]),
                           "只重识别未成功提交的音频，保留失败段及后续内容")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
    }

    func testSingleFailedCommitRecoversWithMoreAudioAndResumesStreaming() {
        var uploadedChunks: [[Float]] = []
        var tailSamples: [Float] = []
        let session = StreamingTranscriptionSession(chunkTranscriber: { samples, done in
            uploadedChunks.append(samples)
            switch uploadedChunks.count {
            case 1, 3: done(.failure(CloudASRTranscriber.TranscriptionError.noSpeech))
            case 2: done(.success("恢复一"))
            default: done(.success("恢复二"))
            }
        }, tailTranscriber: { samples, done in
            tailSamples = samples
            done(.success("尾"))
        })
        let finalSamples = speechWithPauses(blocks: 6)
        let shortSnapshot = Array(finalSamples.prefix(8 * sampleRate))
        XCTAssertTrue(ingestOnce(session, shortSnapshot))
        let firstAttempt = uploadedChunks[0]
        XCTAssertFalse(ingestOnce(session, shortSnapshot), "没有足够的新音频时不能重传同一段")
        XCTAssertEqual(uploadedChunks.count, 1)

        XCTAssertTrue(ingestOnce(session, finalSamples))
        XCTAssertEqual(uploadedChunks.count, 2)
        guard uploadedChunks.count == 2 else { return }
        XCTAssertEqual(Array(uploadedChunks[1].prefix(firstAttempt.count)), firstAttempt,
                       "补救必须保留被误判为无语音的声音")
        XCTAssertGreaterThanOrEqual(uploadedChunks[1].count - firstAttempt.count,
                                    Int(StreamingTranscriptionSession.minCommitSeconds * Double(sampleRate)))
        let firstRecoveredIndex = session.committedIndexForTest
        XCTAssertEqual(firstRecoveredIndex, uploadedChunks[1].count)
        XCTAssertEqual(session.committedText, "恢复一")

        // 成功后正常处理新段；新段的一次误判也可补救，不把一整次录音的容错机会用光。
        XCTAssertTrue(ingestOnce(session, finalSamples))
        XCTAssertEqual(session.committedIndexForTest, firstRecoveredIndex)
        XCTAssertTrue(ingestOnce(session, finalSamples))
        let finalCommittedIndex = session.committedIndexForTest
        XCTAssertGreaterThan(finalCommittedIndex, firstRecoveredIndex)
        XCTAssertEqual(session.committedText, "恢复一恢复二")

        let exp = expectation(description: "finish")
        session.finish(finalSamples: finalSamples) { result in
            guard case .success(let text) = result else { return XCTFail() }
            XCTAssertEqual(text, "恢复一恢复二尾")
            XCTAssertEqual(tailSamples, Array(finalSamples[finalCommittedIndex...]))
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
}

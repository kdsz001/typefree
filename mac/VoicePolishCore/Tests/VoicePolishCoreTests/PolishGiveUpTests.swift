import XCTest
@testable import VoicePolishCore

/// 体检 优10（润色总封顶）：调用方放弃润色（giveUpPolishing）和润色结果谁先到谁收尾，后到的一律丢掉——
/// 不出第二遍字、不记第二条历史、onPolishFailed 只调一次。
final class PolishGiveUpTests: XCTestCase {

    /// 润色结果由测试手动放出；历史不写真实文件，只记下写了几条
    private final class ControlledPolisher: AIPolisher {
        private let lock = NSLock()
        private var _pending: ((Result<String, Error>) -> Void)?
        private var _logs: [(asr: String, output: String)] = []

        var pending: ((Result<String, Error>) -> Void)? { lock.lock(); defer { lock.unlock() }; return _pending }
        var logs: [(asr: String, output: String)] { lock.lock(); defer { lock.unlock() }; return _logs }

        override func isPolishEnabled() -> Bool { true }
        override func applyConfiguredTermCorrections(to text: String) -> String { text }
        override func polishCloudASROutput(text: String, outputLanguage: OutputLanguage? = nil,
                                           completion: @escaping (Result<String, Error>) -> Void) {
            lock.lock(); _pending = completion; lock.unlock()
        }
        override func writePolishLog(asr: String, output: String, durationMs: Int, inputTokens: Int = 0,
                                     outputTokens: Int = 0, id: String? = nil, audioFile: String? = nil) -> Bool {
            lock.lock(); _logs.append((asr, output)); lock.unlock()
            return true
        }
    }

    private final class Recorder {
        private let lock = NSLock()
        private var _done: [String] = []
        private var _failures: [String] = []
        var done: [String] { lock.lock(); defer { lock.unlock() }; return _done }
        var failures: [String] { lock.lock(); defer { lock.unlock() }; return _failures }
        func addDone(_ s: String) { lock.lock(); _done.append(s); lock.unlock() }
        func addFailure(_ s: String) { lock.lock(); _failures.append(s); lock.unlock() }
    }

    /// 超过 10 个有效字（短句不润色），不含「用英文」之类的口令
    private let raw = "明天下午三点在二楼会议室开项目周会，记得带上电脑"
    private let samples = [Float](repeating: 0.05, count: 16000)

    private func makePipeline() -> (VoicePolishPipeline, ControlledPolisher, Recorder) {
        let polisher = ControlledPolisher()
        let pipeline = VoicePolishPipeline(aiPolisher: polisher, cloudTranscriber: CloudASRTranscriber())
        pipeline.audioSaver = nil
        let recorder = Recorder()
        pipeline.onStateChange = { state in
            if case .done(let text) = state { recorder.addDone(text) }
        }
        pipeline.onPolishFailed = { recorder.addFailure($0) }
        return (pipeline, polisher, recorder)
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// 放弃先到：出原文一次、提醒一次、历史一条；晚到的润色成功 / 失败都丢掉
    func testGiveUpFirstDeliversRawOnceAndDropsLateResults() {
        let (pipeline, polisher, recorder) = makePipeline()
        pipeline.processTranscribedText(raw, samples: samples, mode: .cloudOnly)
        guard let late = polisher.pending else { return XCTFail("应已发出润色请求") }
        XCTAssertEqual(pipeline.polishingCharacterCount, raw.count, "润色中能读到交去润色的字数（App 据此定封顶）")

        XCTAssertTrue(pipeline.giveUpPolishing(reason: "网络太慢，等了 28 秒没整理完"))
        XCTAssertEqual(recorder.done, [raw], "放弃后直接出原文")
        XCTAssertEqual(recorder.failures, ["网络太慢，等了 28 秒没整理完"])
        XCTAssertNil(pipeline.polishingCharacterCount)

        late(.success("润色后的版本"))
        late(.failure(AIPolisher.PolishError.apiError("晚到的失败")))
        XCTAssertTrue(waitUntil { polisher.logs.count >= 1 })
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))   // 给可能的第二条历史留时间
        XCTAssertEqual(recorder.done, [raw], "晚到的润色结果不能再出一遍字")
        XCTAssertEqual(recorder.failures.count, 1, "onPolishFailed 只调一次")
        XCTAssertEqual(polisher.logs.count, 1, "历史只记一条")
        XCTAssertEqual(polisher.logs.first?.output, raw)
        XCTAssertFalse(pipeline.giveUpPolishing(reason: "再来一次"), "已经收尾了：再放弃返回 false、什么都不做")
        XCTAssertEqual(recorder.done.count, 1)
    }

    /// 润色先回来：照常出润色稿；之后再放弃返回 false，不重复出字、不提醒
    func testResultFirstThenGiveUpReturnsFalse() {
        let (pipeline, polisher, recorder) = makePipeline()
        pipeline.processTranscribedText(raw, samples: samples, mode: .cloudOnly)
        guard let complete = polisher.pending else { return XCTFail("应已发出润色请求") }

        complete(.success("润色后的版本"))
        XCTAssertEqual(recorder.done, ["润色后的版本"])
        XCTAssertFalse(pipeline.giveUpPolishing(reason: "网络太慢"))
        XCTAssertTrue(waitUntil { polisher.logs.count >= 1 })
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(recorder.done, ["润色后的版本"], "不能再出一遍原文")
        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertEqual(polisher.logs.count, 1)
    }

    /// 润色失败照旧：提醒原因、出原文——和放弃走的是同一段
    func testPolishFailureStillFallsBackToRaw() {
        let (pipeline, polisher, recorder) = makePipeline()
        pipeline.processTranscribedText(raw, samples: samples, mode: .cloudOnly)
        polisher.pending?(.failure(AIPolisher.PolishError.apiError("额度用完了")))
        XCTAssertEqual(recorder.done, [raw])
        XCTAssertEqual(recorder.failures.count, 1)
        XCTAssertFalse(pipeline.giveUpPolishing(reason: "网络太慢"))
    }

    /// 没在润色：什么都不做
    func testGiveUpWhenNotPolishingDoesNothing() {
        let (pipeline, _, recorder) = makePipeline()
        XCTAssertFalse(pipeline.giveUpPolishing(reason: "网络太慢"))
        XCTAssertNil(pipeline.polishingCharacterCount)
        XCTAssertTrue(recorder.done.isEmpty)
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    /// 已取消（Esc）：放弃也什么都不做，晚到的润色结果照旧丢掉
    func testGiveUpAfterCancelDoesNothing() {
        let (pipeline, polisher, recorder) = makePipeline()
        pipeline.processTranscribedText(raw, samples: samples, mode: .cloudOnly)
        XCTAssertTrue(pipeline.cancelCurrent())
        XCTAssertFalse(pipeline.giveUpPolishing(reason: "网络太慢"))
        polisher.pending?(.success("润色后的版本"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(recorder.done.isEmpty)
        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertTrue(polisher.logs.isEmpty)
    }
}

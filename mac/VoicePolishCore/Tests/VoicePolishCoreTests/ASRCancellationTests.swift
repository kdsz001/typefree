import XCTest
@testable import VoicePolishCore

/// 优3（2026-11-19 体检）：取消识别后，已发出的请求要真的掐断，分段识别剩下的段、异步轮询都不再发；
/// 没取消时请求和结果与原来完全一样。
/// 用一个只接管火山识别地址的假网络层（URLProtocol）观察请求，不连真服务器、不读钥匙串。
final class ASRCancellationTests: XCTestCase {

    private var dirs: [URL] = []

    override func setUp() {
        super.setUp()
        StubVolcanoProtocol.reset()
        URLProtocol.registerClass(StubVolcanoProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubVolcanoProtocol.self)
        StubVolcanoProtocol.reset()
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    /// 自带火山 Key（存内存、不碰钥匙串）的转写器 → 直连火山，不走试用 / 会员通道
    private func makeTranscriber(maxConcurrent: Int = 2, version: CloudASRTranscriber.ASRVersion = .turbo) -> CloudASRTranscriber {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("asr-cancel-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let config = VoicePolishConfig(configDir: dir, secrets: InMemorySecretStore())
        config.save(value: "test-key", forKey: "bigasr_api_key")
        config.save(value: String(maxConcurrent), forKey: "chunk_asr_max_concurrent")
        config.save(value: version.rawValue, forKey: "bigasr_version")
        return CloudASRTranscriber(config: config)
    }

    // MARK: - 音频：说话 / 停顿交替，会被切成多段

    private var seed: UInt64 = 7
    private func noise() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
    }
    private func chunkableAudio(blocks: Int = 6) -> [Float] {
        var s: [Float] = []
        for _ in 0..<blocks {
            s += (0..<(5 * 16000)).map { i in 0.2 * sin(2 * .pi * 440 * Float(i) / 16000) + 0.01 * noise() }
            s += (0..<Int(1.2 * 16000)).map { _ in 0.01 * noise() }
        }
        return s
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: - 分段识别

    func testCancelAbortsInFlightChunksAndSendsNoMore() {
        let transcriber = makeTranscriber(maxConcurrent: 2)
        let samples = chunkableAudio()
        let chunkCount = AudioChunker.plan(samples: samples, sampleRate: 16000).count
        XCTAssertGreaterThan(chunkCount, 2, "前置条件：要切成 3 段以上，才测得到「剩下的段不再发」")

        var result: Result<String, Error>?
        let done = expectation(description: "done")
        transcriber.transcribeAuto(samples: samples, version: .turbo) { r in result = r; done.fulfill() }
        XCTAssertTrue(waitUntil { StubVolcanoProtocol.started == 2 }, "并发上限 2：应先发出 2 段")

        transcriber.cancelAllInFlight()
        wait(for: [done], timeout: 5)
        guard case .failure(let error)? = result else { return XCTFail("取消后应以失败收尾") }
        XCTAssertTrue(CloudASRTranscriber.isCancellation(error))

        XCTAssertTrue(waitUntil { StubVolcanoProtocol.stopped == 2 }, "在途的 2 个请求都应被掐断")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(StubVolcanoProtocol.started, 2, "取消后剩下的段一个都不能再发")
    }

    /// 没取消：每段都发、结果按顺序拼接——与改动前一致
    func testWithoutCancelEveryChunkIsSentAndJoined() {
        StubVolcanoProtocol.responder = { _ in (status: "20000000", body: ["result": ["text": "段"]]) }
        let transcriber = makeTranscriber(maxConcurrent: 2)
        let samples = chunkableAudio()
        let chunkCount = AudioChunker.plan(samples: samples, sampleRate: 16000).count

        var result: Result<String, Error>?
        let done = expectation(description: "done")
        transcriber.transcribeAuto(samples: samples, version: .turbo) { r in result = r; done.fulfill() }
        wait(for: [done], timeout: 10)
        guard case .success(let text)? = result else { return XCTFail("应成功：\(String(describing: result))") }
        XCTAssertEqual(text, String(repeating: "段", count: chunkCount))
        XCTAssertEqual(StubVolcanoProtocol.started, chunkCount)
    }

    /// 取消只管当时在途的；之后新发起的识别照常
    func testRecognitionStartedAfterCancelIsUnaffected() {
        let transcriber = makeTranscriber(maxConcurrent: 2)
        transcriber.cancelAllInFlight()
        StubVolcanoProtocol.responder = { _ in (status: "20000000", body: ["result": ["text": "你好"]]) }
        var result: Result<String, Error>?
        let done = expectation(description: "done")
        transcriber.transcribe(samples: Array(chunkableAudio(blocks: 1).prefix(3 * 16000)), version: .turbo) { r in
            result = r; done.fulfill()
        }
        wait(for: [done], timeout: 5)
        guard case .success(let text)? = result else { return XCTFail("应成功：\(String(describing: result))") }
        XCTAssertEqual(text, "你好")
    }

    // MARK: - 异步接口（标准版 / 2.0）：取消后不再轮询

    func testCancelStopsAsyncPolling() {
        StubVolcanoProtocol.responder = { request in
            request.url?.path.hasSuffix("/submit") == true
                ? (status: "20000000", body: [:])
                : (status: "20000001", body: [:])   // 查询：一直「处理中」
        }
        let transcriber = makeTranscriber(maxConcurrent: 1, version: .standard)
        var result: Result<String, Error>?
        let done = expectation(description: "done")
        transcriber.transcribe(samples: Array(chunkableAudio(blocks: 1).prefix(3 * 16000)), version: .standard) { r in
            result = r; done.fulfill()
        }
        XCTAssertTrue(waitUntil { StubVolcanoProtocol.started >= 3 }, "提交后应在轮询")
        transcriber.cancelAllInFlight()
        wait(for: [done], timeout: 5)
        guard case .failure(let error)? = result else { return XCTFail("取消后应以失败收尾") }
        XCTAssertTrue(CloudASRTranscriber.isCancellation(error))
        let afterCancel = StubVolcanoProtocol.started
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))   // 轮询间隔 0.3s，等两三轮
        XCTAssertEqual(StubVolcanoProtocol.started, afterCancel, "取消后不能再发查询")
    }

    // MARK: - App 的取消入口：流水线 cancelCurrent()

    func testPipelineCancelCurrentAbortsRecognitionRequests() {
        let transcriber = makeTranscriber(maxConcurrent: 2)
        let pipeline = VoicePolishPipeline(aiPolisher: AIPolisher(), cloudTranscriber: transcriber)
        let lock = NSLock()
        var states: [String] = []
        pipeline.onStateChange = { state in
            lock.lock(); defer { lock.unlock() }
            switch state {
            case .transcribing: states.append("transcribing")
            case .polishing: states.append("polishing")
            case .done: states.append("done")
            case .error: states.append("error")
            case .empty: states.append("empty")
            }
        }
        pipeline.process(samples: chunkableAudio(), mode: .cloudOnly)
        XCTAssertTrue(waitUntil { StubVolcanoProtocol.started == 2 })

        XCTAssertTrue(pipeline.cancelCurrent())
        XCTAssertTrue(waitUntil { StubVolcanoProtocol.stopped == 2 }, "按 Esc 后在途的识别请求应被掐断")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(StubVolcanoProtocol.started, 2, "取消后剩下的段不再发")
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(states, ["transcribing"], "取消后不能再回调报错 / 出字")
    }
}

/// 只接管火山识别地址（openspeech.bytedance.com）的假网络层。
/// responder 为 nil 时请求一直挂着不回（直到被取消）；否则按它给的状态码 / 响应体回。
private final class StubVolcanoProtocol: URLProtocol {
    typealias Responder = (URLRequest) -> (status: String, body: [String: Any])

    private static let lock = NSLock()
    private static var _responder: Responder?
    private static var _started = 0
    private static var _stopped = 0

    static func reset() {
        lock.lock(); _responder = nil; _started = 0; _stopped = 0; lock.unlock()
    }
    static var responder: Responder? {
        get { lock.lock(); defer { lock.unlock() }; return _responder }
        set { lock.lock(); _responder = newValue; lock.unlock() }
    }
    static var started: Int { lock.lock(); defer { lock.unlock() }; return _started }
    static var stopped: Int { lock.lock(); defer { lock.unlock() }; return _stopped }

    private var finished = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "openspeech.bytedance.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._started += 1
        let responder = Self._responder
        Self.lock.unlock()
        guard let responder, let url = request.url else { return }   // 挂着不回
        let answer = responder(request)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["X-Api-Status-Code": answer.status])!
        finished = true
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: answer.body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard !finished else { return }   // 正常回完的不算「被掐断」
        Self.lock.lock(); Self._stopped += 1; Self.lock.unlock()
    }
}

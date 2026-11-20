import XCTest
@testable import VoicePolishCore

/// 体检 优3 补齐：试用 / 会员通道的识别请求经 TrialManager 发出，以前拿不到任务句柄、取消时掐不断。
/// 现在 hostedPost / trialPost / memberPost（含 401 换令牌后重发的那一次）都把任务交给调用方登记，
/// 识别的取消标记一取消就当场掐断。用注入的假网络层（URLProtocol）观察，不连真服务器。
final class HostedRequestCancellationTests: XCTestCase {

    private var suiteName = ""

    override func setUp() {
        super.setUp()
        StubTrialProtocol.reset()
        suiteName = "hosted-cancel-\(UUID().uuidString)"
    }

    override func tearDown() {
        StubTrialProtocol.reset()
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTrialProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeManager() -> TrialManager {
        TrialManager(defaults: UserDefaults(suiteName: suiteName)!, session: makeSession(), apiBase: "https://trial.test")
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private final class Box<T> {
        private let lock = NSLock()
        private var _items: [T] = []
        var items: [T] { lock.lock(); defer { lock.unlock() }; return _items }
        func add(_ x: T) { lock.lock(); _items.append(x); lock.unlock() }
    }

    /// 发出的请求交给调用方；调用方取消 → 连接当场断开，回调收到「已取消」
    func testTrialPostHandsOutTaskAndCancelAbortsConnection() {
        let manager = makeManager()
        let tasks = Box<URLSessionTask>()
        var gotError: Error?
        let done = expectation(description: "completion")
        manager.trialPost(path: "/trial/asr", jsonBody: ["x": 1], onTask: { tasks.add($0) }) { _, _, error in
            gotError = error
            done.fulfill()
        }
        XCTAssertTrue(waitUntil { StubTrialProtocol.started(path: "/trial/asr") == 1 }, "请求应已发出（假服务器一直不回）")
        XCTAssertEqual(tasks.items.count, 1)

        tasks.items.first?.cancel()
        wait(for: [done], timeout: 5)
        XCTAssertEqual((gotError as NSError?)?.code, NSURLErrorCancelled)
        XCTAssertTrue(waitUntil { StubTrialProtocol.stopped == 1 }, "连接应被掐断")
    }

    /// 401 换令牌后重发的那一次也要交出来，否则取消时这一次掐不断
    func testTrialPostRetryAfterTokenRefreshIsAlsoHandedOut() {
        StubTrialProtocol.responder = { request, asrCount in
            switch request.url?.path {
            case "/trial/asr" where asrCount == 1: return (401, ["error": "试用令牌无效", "code": "bad_trial_token"])
            case "/trial/asr": return nil   // 重发的那一次一直挂着
            case "/trial/start": return (200, ["trial_token": "tok-new", "days_left": 6])
            default: return (404, [:])
            }
        }
        let manager = makeManager()
        let tasks = Box<URLSessionTask>()
        var gotError: Error?
        let done = expectation(description: "completion")
        manager.trialPost(path: "/trial/asr", jsonBody: [:], onTask: { tasks.add($0) }) { _, _, error in
            gotError = error
            done.fulfill()
        }
        XCTAssertTrue(waitUntil { StubTrialProtocol.started(path: "/trial/asr") == 2 }, "401 后应换令牌并重发一次")
        XCTAssertEqual(tasks.items.count, 2, "重发的那一次也要交给调用方登记")

        tasks.items.last?.cancel()
        wait(for: [done], timeout: 5)
        XCTAssertEqual((gotError as NSError?)?.code, NSURLErrorCancelled)
        XCTAssertTrue(waitUntil { StubTrialProtocol.stopped == 1 })
    }

    /// 会员通道同样交出任务
    func testMemberPostHandsOutTask() {
        let manager = makeManager()
        let tasks = Box<URLSessionTask>()
        let done = expectation(description: "completion")
        manager.hostedPost(route: .member, endpoint: "asr", jsonBody: [:], timeout: 30, onTask: { tasks.add($0) }) { _, _, _ in
            done.fulfill()
        }
        XCTAssertTrue(waitUntil { StubTrialProtocol.started(path: "/member/asr") == 1 })
        XCTAssertEqual(tasks.items.count, 1)
        tasks.items.first?.cancel()
        wait(for: [done], timeout: 5)
        XCTAssertTrue(waitUntil { StubTrialProtocol.stopped == 1 })
    }

    /// 不传 onTask：行为与原来一样，照常拿到服务器的回应
    func testWithoutOnTaskBehaviorUnchanged() {
        StubTrialProtocol.responder = { _, _ in (200, ["ok": true]) }
        let manager = makeManager()
        var status: Int?
        let done = expectation(description: "completion")
        manager.hostedPost(route: .trial, endpoint: "asr", jsonBody: [:]) { _, response, _ in
            status = response?.statusCode
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(status, 200)
    }

    // MARK: - 识别这一侧：登记到取消标记

    /// 登记后取消标记一取消，托管请求就被掐断
    func testRegisteredTaskIsAbortedWhenRecognitionIsCancelled() {
        let token = CloudASRTranscriber.CancelToken()
        var gotError: Error?
        let done = expectation(description: "completion")
        let manager = makeManager()
        manager.trialPost(path: "/trial/asr", jsonBody: [:], onTask: { CloudASRTranscriber.register($0, with: token) }) { _, _, error in
            gotError = error
            done.fulfill()
        }
        XCTAssertTrue(waitUntil { StubTrialProtocol.started(path: "/trial/asr") == 1 })
        token.cancel()
        wait(for: [done], timeout: 5)
        XCTAssertEqual((gotError as NSError?)?.code, NSURLErrorCancelled)
        XCTAssertTrue(waitUntil { StubTrialProtocol.stopped == 1 }, "取消识别时试用 / 会员的请求也要真的断开")
    }

    /// 登记时已经取消了（如换令牌途中用户按了 Esc）：重发的请求当场取消，根本不发出去
    func testTaskRegisteredAfterCancelIsCancelledBeforeSending() {
        let token = CloudASRTranscriber.CancelToken()
        token.cancel()
        var gotError: Error?
        let done = expectation(description: "completion")
        makeManager().trialPost(path: "/trial/asr", jsonBody: [:], onTask: { CloudASRTranscriber.register($0, with: token) }) { _, _, error in
            gotError = error
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual((gotError as NSError?)?.code, NSURLErrorCancelled)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(StubTrialProtocol.started(path: "/trial/asr"), 0, "已取消就不该再发")
    }
}

/// 只接管 trial.test 的假服务器。responder 返回 nil = 一直挂着不回（直到被取消）；
/// 第二个参数是这个路径到目前为止第几次被请求（从 1 开始）。
private final class StubTrialProtocol: URLProtocol {
    typealias Responder = (_ request: URLRequest, _ countForPath: Int) -> (status: Int, body: [String: Any])?

    private static let lock = NSLock()
    private static var _responder: Responder?
    private static var _started: [String: Int] = [:]
    private static var _stopped = 0

    static func reset() {
        lock.lock(); _responder = nil; _started = [:]; _stopped = 0; lock.unlock()
    }
    static var responder: Responder? {
        get { lock.lock(); defer { lock.unlock() }; return _responder }
        set { lock.lock(); _responder = newValue; lock.unlock() }
    }
    static func started(path: String) -> Int { lock.lock(); defer { lock.unlock() }; return _started[path] ?? 0 }
    static var stopped: Int { lock.lock(); defer { lock.unlock() }; return _stopped }

    private var finished = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "trial.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self._started[path, default: 0] += 1
        let count = Self._started[path] ?? 0
        let responder = Self._responder
        Self.lock.unlock()
        guard let answer = responder?(request, count), let url = request.url else { return }   // 挂着不回
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: nil, headerFields: nil)!
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

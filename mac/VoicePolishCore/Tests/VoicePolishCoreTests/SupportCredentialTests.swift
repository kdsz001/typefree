import XCTest
@testable import VoicePolishCore

/// 体检优9：反馈凭证只存在偏好设置里，清过偏好设置的用户之后一律 403「凭证不对」、再也发不了工单。
/// 现在：凭证（和反馈专用标识）在钥匙串里另存一份能找回；真丢了（服务器回 bad_secret）就换新标识自动重开一次。
/// 钥匙串用内存假实现，不碰真钥匙串；网络用假网络层，不连真服务器。
final class SupportCredentialTests: XCTestCase {

    private var dir: URL!
    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("support-cred-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "support-cred-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        SupportStubProtocol.reset()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
        SupportStubProtocol.reset()
        super.tearDown()
    }

    private func makeService(store: SecretStoring? = InMemorySecretStore()) -> SupportChatService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SupportStubProtocol.self]
        let service = SupportChatService(defaults: suite, storeDir: dir, apiBase: "https://support.example.invalid",
                                         session: URLSession(configuration: config), secretStore: store)
        service.waitForSecretStore()
        return service
    }

    private func out(_ text: String, image: Data? = nil) -> SupportChatService.Outgoing {
        SupportChatService.Outgoing(text: text, imageJPEG: image, deviceName: "Mac", appVersion: "3.0")
    }

    private static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
    private var baseID: String { LicenseManager.shared.deviceID() }

    private func ticketJSON(id: Int) -> [String: Any] {
        ["id": id, "no": 1000 + id, "category": "other", "title": "t", "status": "open", "created_at": "2026-11-20 00:00:00"]
    }

    // MARK: - 钥匙串找回 / 补存

    func testSecretAndFeedbackIDRestoredFromKeychainWhenPreferencesLost() {
        let store = InMemorySecretStore()
        store.set("support.secret", "kept-secret")
        store.set("support.deviceId", "\(baseID).0123456789abcdef")
        let service = makeService(store: store)
        XCTAssertTrue(service.hasThread)
        XCTAssertEqual(suite.string(forKey: "support.secret"), "kept-secret")
        XCTAssertEqual(service.feedbackDeviceID, "\(baseID).0123456789abcdef")
    }

    func testExistingSecretIsBackedUpToKeychain() {
        suite.set("old-user-secret", forKey: "support.secret")
        let store = InMemorySecretStore()
        let service = makeService(store: store)
        XCTAssertEqual(store.get("support.secret"), "old-user-secret", "老用户升级后要在钥匙串补存一份")
        XCTAssertNil(store.get("support.deviceId"), "没重开过对话的用户没有专用标识")
        XCTAssertEqual(service.feedbackDeviceID, baseID)
    }

    /// 钥匙串读不出来（工单里出现过）：不崩、不改任何东西，保持原来的行为
    func testKeychainReadErrorKeepsCurrentBehavior() {
        let service = makeService(store: FailingSecretStore())
        XCTAssertFalse(service.hasThread)
        XCTAssertNil(suite.string(forKey: "support.secret"))
        XCTAssertEqual(service.feedbackDeviceID, baseID)
    }

    func testNoKeychainStoreKeepsOldBehavior() {
        let service = makeService(store: nil)
        XCTAssertFalse(service.hasThread)
    }

    func testNewSecretFromServerIsSavedToPreferencesAndKeychain() {
        let store = InMemorySecretStore()
        let service = makeService(store: store)
        SupportStubProtocol.handler = { _ in (200, ["id": 1, "ticket_id": 5, "ticket": self.ticketJSON(id: 5), "secret": "fresh"]) }
        let done = expectation(description: "create")
        service.createTicket(category: .issue, out("闪退了")) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        service.waitForSecretStore()
        XCTAssertEqual(suite.string(forKey: "support.secret"), "fresh")
        XCTAssertEqual(store.get("support.secret"), "fresh")
    }

    // MARK: - 凭证不对 → 换新标识自动重开一次

    func testBadSecretOnCreateReopensWithNewFeedbackID() {
        suite.set("stale", forKey: "support.secret")
        let store = InMemorySecretStore()
        let service = makeService(store: store)
        service.replaceTickets([SupportTicket(id: 1, no: 1001, category: .issue, title: "旧工单", status: .open, createdAt: "")])
        service.append([SupportMessage(id: 9, role: .admin, text: "旧回复", createdAt: "", ticketId: 1)])

        SupportStubProtocol.handler = { body in
            if body["secret"] as? String == "stale" {
                return (403, ["error": "凭证不对，请重新开始对话", "code": "bad_secret"])
            }
            return (200, ["id": 20, "ticket_id": 7, "ticket": self.ticketJSON(id: 7), "secret": "new-secret"])
        }
        var result: Result<(ticket: SupportTicket, attachmentsDropped: Bool), SupportChatError>?
        let done = expectation(description: "create")
        service.createTicket(category: .issue, out("又闪退了")) { r in result = r; done.fulfill() }
        wait(for: [done], timeout: 5)
        service.waitForSecretStore()

        guard case .success(let created)? = result else { return XCTFail("应自动重开成功：\(String(describing: result))") }
        XCTAssertEqual(created.ticket.id, 7)
        let bodies = SupportStubProtocol.bodies
        XCTAssertEqual(bodies.count, 2, "只重发一次")
        XCTAssertEqual(bodies[0]["device_id"] as? String, baseID)
        let newID = bodies[1]["device_id"] as? String ?? ""
        XCTAssertTrue(newID.hasPrefix(baseID + "."), newID)
        XCTAssertEqual(newID.count, baseID.count + 17, "设备标识 + . + 16 位十六进制")
        XCTAssertTrue(SupportChatService.isValidFeedbackDeviceID(newID))
        XCTAssertNil(bodies[1]["secret"], "新标识第一条不带凭证")
        XCTAssertEqual(bodies[1]["text"] as? String, "又闪退了")

        XCTAssertEqual(service.feedbackDeviceID, newID)
        XCTAssertEqual(suite.string(forKey: "support.secret"), "new-secret")
        XCTAssertEqual(store.get("support.secret"), "new-secret")
        XCTAssertEqual(store.get("support.deviceId"), newID)
        XCTAssertEqual(service.tickets.map(\.id), [7], "旧工单的本地缓存要清掉")
        XCTAssertEqual(service.messages.map(\.id), [20])
    }

    /// 重开后还是凭证不对：不再重开（防死循环），交给界面
    func testReopenHappensOnlyOnce() {
        suite.set("stale", forKey: "support.secret")
        let service = makeService()
        SupportStubProtocol.handler = { _ in (403, ["error": "凭证不对，请重新开始对话", "code": "bad_secret"]) }
        var result: Result<(ticket: SupportTicket, attachmentsDropped: Bool), SupportChatError>?
        let done = expectation(description: "create")
        service.createTicket(category: .issue, out("x")) { r in result = r; done.fulfill() }
        wait(for: [done], timeout: 5)
        guard case .failure(let err)? = result else { return XCTFail() }
        XCTAssertEqual(err, .credentialRejected)
        XCTAssertEqual(SupportStubProtocol.bodies.count, 2)
    }

    /// 设备被停用：不重开
    func testBlockedDoesNotReopen() {
        suite.set("s", forKey: "support.secret")
        let service = makeService()
        SupportStubProtocol.handler = { _ in (403, ["error": "该设备已被停用反馈", "code": "blocked"]) }
        var result: Result<(ticket: SupportTicket, attachmentsDropped: Bool), SupportChatError>?
        let done = expectation(description: "create")
        service.createTicket(category: .issue, out("x")) { r in result = r; done.fulfill() }
        wait(for: [done], timeout: 5)
        guard case .failure(let err)? = result else { return XCTFail() }
        XCTAssertEqual(err, .blocked)
        XCTAssertEqual(SupportStubProtocol.bodies.count, 1)
        XCTAssertEqual(service.feedbackDeviceID, baseID)
        XCTAssertEqual(suite.string(forKey: "support.secret"), "s")
    }

    /// 同一 IP 新标识开太多：显示服务器的中文原话
    func testThreadCapShowsServerMessage() {
        suite.set("stale", forKey: "support.secret")
        let service = makeService()
        SupportStubProtocol.handler = { body in
            body["secret"] as? String == "stale"
                ? (403, ["error": "凭证不对，请重新开始对话", "code": "bad_secret"])
                : (429, ["error": "今天新开的对话太多了，明天再来", "code": "thread_cap"])
        }
        var result: Result<(ticket: SupportTicket, attachmentsDropped: Bool), SupportChatError>?
        let done = expectation(description: "create")
        service.createTicket(category: .issue, out("x")) { r in result = r; done.fulfill() }
        wait(for: [done], timeout: 5)
        guard case .failure(let err)? = result else { return XCTFail() }
        XCTAssertEqual(err.userMessage, "发送失败：今天新开的对话太多了，明天再来")
    }

    /// 在旧工单里回复时凭证不对：开成新工单发出去，截图紧跟着补发进新工单
    func testBadSecretOnReplyOpensNewTicketAndResendsAttachment() {
        suite.set("stale", forKey: "support.secret")
        let service = makeService()
        SupportStubProtocol.handler = { body in
            if body["secret"] as? String == "stale" { return (403, ["error": "凭证不对，请重新开始对话", "code": "bad_secret"]) }
            if body["secret"] == nil {   // 新标识第一条：开工单，服务器丢掉附件
                return (200, ["id": 30, "ticket_id": 8, "ticket": self.ticketJSON(id: 8), "secret": "new", "attachments_dropped": true])
            }
            return (200, ["id": 31, "ticket_id": 8])   // 补发附件
        }
        var result: Result<SupportMessage, SupportChatError>?
        let done = expectation(description: "send")
        service.send(out("还是不行", image: Self.jpeg), ticketId: 1) { r in result = r; done.fulfill() }
        wait(for: [done], timeout: 5)
        guard case .success(let msg)? = result else { return XCTFail("应成功：\(String(describing: result))") }
        XCTAssertEqual(msg.ticketId, 8)

        let bodies = SupportStubProtocol.bodies
        let paths = SupportStubProtocol.paths
        XCTAssertEqual(paths, ["/support/send", "/support/tickets/create", "/support/send"])
        XCTAssertEqual(bodies[1]["category"] as? String, "other")
        XCTAssertNil(bodies[1]["ticket_id"], "旧工单属于旧标识，不能再往里发")
        XCTAssertEqual(bodies[2]["ticket_id"] as? Int, 8)
        XCTAssertEqual(bodies[2]["image_b64"] as? String, Self.jpeg.base64EncodedString())
        XCTAssertEqual(bodies[2]["secret"] as? String, "new")
        XCTAssertEqual(Set(service.messages.map(\.id)), [30, 31])
    }

    /// 拉新回复时凭证不对：只换标识、清凭证和旧缓存，不发消息
    func testSyncBadSecretOnlyResetsIdentity() {
        suite.set("stale", forKey: "support.secret")
        let service = makeService()
        service.replaceTickets([SupportTicket(id: 1, no: 1001, category: .issue, title: "旧", status: .open, createdAt: "")])
        SupportStubProtocol.handler = { _ in (403, ["error": "凭证不对，请重新开始对话", "code": "bad_secret"]) }
        let done = expectation(description: "sync")
        service.sync { ok in XCTAssertFalse(ok); done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(SupportStubProtocol.bodies.count, 1)
        XCTAssertFalse(service.hasThread)
        XCTAssertNotEqual(service.feedbackDeviceID, baseID)
        XCTAssertTrue(service.feedbackDeviceID.hasPrefix(baseID + "."))
        XCTAssertTrue(service.tickets.isEmpty)
    }

    /// 服务器还没部署 bad_secret 前回的是 403 forbidden：同样认
    func testOldServerForbiddenCodeCountsAsBadSecret() {
        XCTAssertEqual(SupportChatService.classify(code: 403, json: ["code": "bad_secret", "error": "凭证不对，请重新开始对话"]), .credentialRejected)
        XCTAssertEqual(SupportChatService.classify(code: 403, json: ["code": "forbidden", "error": "凭证不对，请重新开始对话"]), .credentialRejected)
        XCTAssertEqual(SupportChatService.classify(code: 403, json: ["code": "blocked"]), .blocked)
    }

    func testFeedbackDeviceIDFormat() {
        let id = SupportChatService.makeFeedbackDeviceID(base: "0123456789abcdef0123456789abcdef")
        XCTAssertTrue(SupportChatService.isValidFeedbackDeviceID(id))
        XCTAssertNotNil(id.range(of: #"^0123456789abcdef0123456789abcdef\.[0-9a-f]{16}$"#, options: .regularExpression))
        XCTAssertNotEqual(id, SupportChatService.makeFeedbackDeviceID(base: "0123456789abcdef0123456789abcdef"))
        XCTAssertFalse(SupportChatService.isValidFeedbackDeviceID("短"))
        XCTAssertFalse(SupportChatService.isValidFeedbackDeviceID("has space in it"))
    }
}

/// 读什么都报错的钥匙串（模拟「钥匙串读不出」）
private final class FailingSecretStore: SecretStoring {
    func get(_ account: String) -> String? { nil }
    func lookup(_ account: String) -> SecretLookup { .error("simulated keychain failure") }
    func set(_ account: String, _ value: String?) -> Bool { XCTFail("读不出时不该写"); return false }
}

/// 假的工单服务器：handler 拿到请求体（JSON）回 (状态码, JSON)
private final class SupportStubProtocol: URLProtocol {
    typealias Handler = (_ body: [String: Any]) -> (Int, [String: Any])
    private static let lock = NSLock()
    private static var _handler: Handler?
    private static var _bodies: [[String: Any]] = []
    private static var _paths: [String] = []

    static func reset() { lock.lock(); _handler = nil; _bodies = []; _paths = []; lock.unlock() }
    static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }
    static var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _bodies }
    static var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = request.httpBody ?? request.httpBodyStream.map(Self.readAll) ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        Self.lock.lock()
        Self._bodies.append(body)
        Self._paths.append(request.url?.path ?? "")
        let handler = Self._handler
        Self.lock.unlock()
        let (status, json) = handler?(body) ?? (500, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

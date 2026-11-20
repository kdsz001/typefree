import XCTest
@testable import VoicePolishCore

final class SupportChatTests: XCTestCase {
    private func out(text: String = "hi", image: Data? = nil, audio: Data? = nil, log: String? = nil) -> SupportChatService.Outgoing {
        SupportChatService.Outgoing(text: text, imageJPEG: image, audioM4A: audio, log: log,
                                    deviceName: "Mac", appVersion: "3.0")
    }

    func testEmptyMessageWithoutAttachmentIsRejected() {
        XCTAssertNil(SupportChatService.makePayload(out(text: "   "), deviceID: "d", secret: nil, osVersion: "26.0"))
    }

    func testImageOnlyMessageIsAllowedAndBase64Encoded() {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let p = SupportChatService.makePayload(out(text: "", image: png), deviceID: "d", secret: "s", osVersion: "26.0")
        XCTAssertEqual(p?["image_b64"] as? String, png.base64EncodedString())
        XCTAssertEqual(p?["secret"] as? String, "s")
        XCTAssertEqual(p?["text"] as? String, "")
    }

    func testOversizeAttachmentsAreDroppedNotSent() {
        let big = Data(count: SupportChatService.maxImageBytes + 1)
        let p = SupportChatService.makePayload(out(text: "x", image: big), deviceID: "d", secret: nil, osVersion: "26.0")
        XCTAssertNil(p?["image_b64"], "超限的截图不该上传")
        XCTAssertNil(p?["secret"], "首次发消息没有凭证")
    }

    func testLogIsTruncatedFromTheEnd() {
        let long = String(repeating: "a", count: SupportChatService.maxLogChars) + "TAIL"
        let p = SupportChatService.makePayload(out(log: long), deviceID: "d", secret: nil, osVersion: "26.0")
        let log = p?["log"] as? String
        XCTAssertEqual(log?.count, SupportChatService.maxLogChars)
        XCTAssertTrue(log?.hasSuffix("TAIL") == true, "留最新的一段")
    }

    func testUnreadCountsOnlyAdminMessagesAfterLastSeen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("support-test-\(UUID().uuidString)")
        let suite = UserDefaults(suiteName: "support-test-\(UUID().uuidString)")!
        let list = [
            SupportMessage(id: 1, role: .user, text: "q", createdAt: "2026-09-15 08:00:00"),
            SupportMessage(id: 2, role: .admin, text: "a", createdAt: "2026-09-15 08:01:00"),
            SupportMessage(id: 3, role: .admin, text: "b", createdAt: "2026-09-15 08:02:00"),
        ]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: dir.appendingPathComponent("support.json"))
        let service = SupportChatService(defaults: suite, storeDir: dir, apiBase: "http://127.0.0.1:1")
        XCTAssertEqual(service.messages.count, 3)
        XCTAssertEqual(service.unreadCount, 2)
        service.markAllSeen()
        XCTAssertEqual(service.unreadCount, 0)
        XCTAssertFalse(service.hasThread)
    }

    // MARK: - 工单

    func testPayloadCarriesTicketIdOrCategory() {
        let send = SupportChatService.makePayload(out(text: "补充"), deviceID: "d", secret: "s", osVersion: "26.0", ticketId: 7)
        XCTAssertEqual(send?["ticket_id"] as? Int, 7)
        XCTAssertNil(send?["category"])
        let create = SupportChatService.makePayload(out(text: "问题"), deviceID: "d", secret: nil, osVersion: "26.0", category: .idea)
        XCTAssertEqual(create?["category"] as? String, "idea")
        XCTAssertNil(create?["ticket_id"])
    }

    func testTicketJSONParsingFallsBackForUnknownValues() {
        let t = SupportTicket(json: ["id": 3, "no": 1003, "category": "issue", "title": "闪退", "status": "closed",
                                    "created_at": "2026-09-17 10:00:00", "closed_at": "2026-09-17 11:00:00"])
        XCTAssertEqual(t, SupportTicket(id: 3, no: 1003, category: .issue, title: "闪退", status: .closed,
                                        createdAt: "2026-09-17 10:00:00", closedAt: "2026-09-17 11:00:00"))
        let odd = SupportTicket(json: ["id": 4, "category": "hack", "status": "weird"])
        XCTAssertEqual(odd?.category, .other)
        XCTAssertEqual(odd?.status, .open)
        XCTAssertEqual(odd?.no, 1004)
        XCTAssertNil(SupportTicket(json: ["title": "没有 id"]))
    }

    func testClassifyPrefersServerMessageAndMapsTicketClosed() {
        XCTAssertEqual(SupportChatService.classify(code: 409, json: ["code": "ticket_closed", "error": "x"]), .ticketClosed)
        XCTAssertEqual(SupportChatService.classify(code: 429, json: ["code": "too_many_open", "error": "处理中的工单太多了"]), .network("处理中的工单太多了"))
        XCTAssertEqual(SupportChatService.classify(code: 403, json: ["code": "blocked"]), .blocked)
        XCTAssertEqual(SupportChatService.classify(code: 0, json: nil), .network("网络不通"))
        XCTAssertEqual(SupportChatService.classify(code: 502, json: ["error": "bad gateway"]), .network("服务器返回 502"))
    }

    /// 修4：发工单时断网 / 超时，以前显示系统原话（error.localizedDescription，英文、可能带服务器地址）
    func testNetworkFailureShowsChineseShortSentence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("support-test-\(UUID().uuidString)")
        let suite = UserDefaults(suiteName: "support-test-\(UUID().uuidString)")!
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TimingOutURLProtocol.self]
        let service = SupportChatService(defaults: suite, storeDir: dir, apiBase: "https://support.example.invalid",
                                         session: URLSession(configuration: config))
        let done = expectation(description: "create")
        service.createTicket(category: .issue, out(text: "闪退了")) { result in
            guard case .failure(let err) = result else { XCTFail("应失败"); done.fulfill(); return }
            XCTAssertEqual(err, .network("网络超时"))
            XCTAssertEqual(err.userMessage, "发送失败：网络超时")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testUnreadIsCountedPerTicketAndOpenTicketsSortFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("support-test-\(UUID().uuidString)")
        let suite = UserDefaults(suiteName: "support-test-\(UUID().uuidString)")!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let service = SupportChatService(defaults: suite, storeDir: dir, apiBase: "http://127.0.0.1:1")
        service.replaceTickets([
            SupportTicket(id: 1, no: 1001, category: .issue, title: "旧的", status: .closed, createdAt: "", closedAt: ""),
            SupportTicket(id: 2, no: 1002, category: .idea, title: "新的", status: .open, createdAt: ""),
            SupportTicket(id: 3, no: 1003, category: .other, title: "更新的", status: .open, createdAt: ""),
        ])
        service.append([
            SupportMessage(id: 10, role: .user, text: "q", createdAt: "", ticketId: 1),
            SupportMessage(id: 11, role: .admin, text: "a", createdAt: "", ticketId: 1),
            SupportMessage(id: 12, role: .user, text: "q2", createdAt: "", localImageFile: "img-12.jpg", ticketId: 2),
            SupportMessage(id: 13, role: .admin, text: "b", createdAt: "", ticketId: 2),
            SupportMessage(id: 14, role: .admin, text: "c", createdAt: "", ticketId: 2),
        ])
        XCTAssertEqual(service.sortedTickets.map(\.id), [3, 2, 1])
        XCTAssertEqual(service.unreadCount(ticket: 1), 1)
        XCTAssertEqual(service.unreadCount(ticket: 2), 2)
        XCTAssertEqual(service.unreadCount, 3)
        service.markTicketSeen(2)
        XCTAssertEqual(service.unreadCount(ticket: 2), 0)
        XCTAssertEqual(service.unreadCount, 1)
        // 同步回来的同一条消息不带本机截图文件名：合并时保留
        service.append([SupportMessage(id: 12, role: .user, text: "q2", createdAt: "", ticketId: 2)])
        XCTAssertEqual(service.messages(inTicket: 2).first?.localImageFile, "img-12.jpg")
        // 重开服务：工单和消息都从本机缓存读回（落盘在后台队列，等文件写好）
        // ⚠ 必须同时等「工单」和「消息」两个文件：它们共用一个串行队列，工单先入队先落盘，
        // 只等工单的话在慢机器上消息还没写完就断言，CI 上就会偶发 messages.count == 0（2026-09-21 踩过）。
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let probe = SupportChatService(defaults: suite, storeDir: dir, apiBase: "x")
            if probe.tickets.count >= 3, probe.messages.count >= 5 { break }
            usleep(20_000)
        }
        let again = SupportChatService(defaults: suite, storeDir: dir, apiBase: "http://127.0.0.1:1")
        XCTAssertEqual(Set(again.tickets.map(\.id)), [1, 2, 3])
        XCTAssertEqual(again.messages.count, 5)
    }

    func testOldCachedMessagesWithoutTicketStillDecodeAndCountAsUnread() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("support-test-\(UUID().uuidString)")
        let suite = UserDefaults(suiteName: "support-test-\(UUID().uuidString)")!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 3.0.2 写的缓存：没有 ticketId 字段
        let old = #"[{"id":1,"role":"user","text":"q","hasImage":false,"hasAudio":false,"createdAt":"x"},{"id":2,"role":"admin","text":"a","hasImage":false,"hasAudio":false,"createdAt":"x"}]"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("support.json"))
        let service = SupportChatService(defaults: suite, storeDir: dir, apiBase: "http://127.0.0.1:1")
        XCTAssertEqual(service.messages.count, 2)
        XCTAssertNil(service.messages[0].ticketId)
        XCTAssertEqual(service.unreadCount, 1)
    }
}

/// 所有请求都以「超时」失败，系统描述里故意带上服务器地址
private final class TimingOutURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSLocalizedDescriptionKey: "The request timed out.",
            NSURLErrorFailingURLStringErrorKey: "https://203.0.113.7:8443/support/tickets/create",
        ])
        client?.urlProtocol(self, didFailWithError: err)
    }
    override func stopLoading() {}
}

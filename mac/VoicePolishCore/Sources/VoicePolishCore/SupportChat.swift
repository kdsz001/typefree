import Foundation

/// 反馈工单（设置窗侧栏「反馈」页）：用户不登录，凭设备标识 + 服务器首次发的随机凭证认人。
/// 2026-09-17 起按工单组织：一台设备可以有多个工单，每个工单一段对话；开发者在后台结束后只能看、不能再回。
/// 工单和消息在本机各存一份（`support-tickets.json` / `support.json`），打开页面或定时去服务器拉；未读按工单算，侧栏角标是总数。
/// 服务器只收 App 自己转码过的 JPEG/PNG 截图和 m4a 录音，这里只负责打包、发送、缓存。
public struct SupportMessage: Codable, Equatable {
    public enum Role: String, Codable { case user, admin }
    public var id: Int
    public var role: Role
    public var text: String
    public var hasImage: Bool
    public var hasAudio: Bool
    public var createdAt: String          // ISO8601 / "YYYY-MM-DD HH:MM:SS"（UTC）
    public var localImageFile: String?    // 自己发的截图在本机的缓存文件名（服务器不回传图）
    public var ticketId: Int?             // 工单上线前缓存的老消息没有，下次同步补上

    public init(id: Int, role: Role, text: String, hasImage: Bool = false, hasAudio: Bool = false,
                createdAt: String, localImageFile: String? = nil, ticketId: Int? = nil) {
        self.id = id; self.role = role; self.text = text; self.hasImage = hasImage; self.hasAudio = hasAudio
        self.createdAt = createdAt; self.localImageFile = localImageFile; self.ticketId = ticketId
    }
}

public struct SupportTicket: Codable, Equatable {
    public enum Status: String, Codable { case open, closed }
    public enum Category: String, Codable, CaseIterable {
        case issue, idea, other
        public var label: String {
            switch self {
            case .issue: return "使用问题"
            case .idea: return "功能建议"
            case .other: return "其他"
            }
        }
    }

    public var id: Int
    public var no: Int                    // 给人看的编号（服务器给，#1001 起）
    public var category: Category
    public var title: String
    public var status: Status
    public var createdAt: String
    public var closedAt: String?

    public init(id: Int, no: Int, category: Category, title: String, status: Status, createdAt: String, closedAt: String? = nil) {
        self.id = id; self.no = no; self.category = category; self.title = title
        self.status = status; self.createdAt = createdAt; self.closedAt = closedAt
    }

    /// 服务器 JSON → 工单；未知的类型/状态按「其他」「处理中」兜底，缺关键字段返回 nil
    public init?(json t: [String: Any]) {
        guard let id = t["id"] as? Int else { return nil }
        self.id = id
        no = t["no"] as? Int ?? id + 1000
        category = Category(rawValue: t["category"] as? String ?? "") ?? .other
        title = t["title"] as? String ?? ""
        status = Status(rawValue: t["status"] as? String ?? "") ?? .open
        createdAt = t["created_at"] as? String ?? ""
        closedAt = t["closed_at"] as? String
    }
}

public enum SupportChatError: Error, Equatable {
    case empty
    case tooLarge
    case blocked
    case ticketClosed
    /// 服务器说反馈凭证不对（403 bad_secret；老服务器是 403 forbidden）。发消息 / 开工单时会自动换新标识重开一次，
    /// 重开后还这样才会交到界面上。
    case credentialRejected
    case network(String)

    public var userMessage: String {
        switch self {
        case .empty: return "写点内容或附上截图再发"
        case .tooLarge: return "附件太大了"
        case .blocked: return "这台设备已被停用反馈"
        case .ticketClosed: return "这个工单已结束，有新问题请提交新工单"
        case .credentialRejected: return "发送失败：反馈凭证对不上，请稍后再试"
        case .network(let s): return "发送失败：\(s)"
        }
    }
}

public final class SupportChatService {
    public static let shared = SupportChatService(secretStore: SupportChatService.platformSecretStore)

    /// 反馈凭证（和反馈专用标识）在钥匙串里另存一份：清过偏好设置 / 重装后从这里找回，
    /// 不然服务器一直回「凭证不对」、这台电脑再也发不了工单（体检优9）。
    static var platformSecretStore: SecretStoring? {
        #if os(iOS)
        return KeychainSecretStore(service: "com.voicepolish.support", accessGroup: "NHC4C4K7X7.com.voicepolish.shared")
        #else
        return KeychainSecretStore(service: "com.voicepolish.support")
        #endif
    }

    /// 工单或消息有变化（发出、收到回复、状态变、未读数变）时发，主线程
    public static let didChangeNotification = Notification.Name("SupportChatDidChange")

    public static let maxImageBytes = 1_500_000
    public static let maxAudioBytes = 1_900_000
    public static let maxTextChars = 4000
    public static let maxLogChars = 12_000
    /// 拉新回复的最短间隔：后台定时器用
    public static let pollInterval: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let secretStore: SecretStoring?
    private let session: URLSession
    private let storeDir: URL
    private let apiBaseOverride: String?
    private let kSecret = "support.secret"
    /// 反馈专用标识：凭证丢了重开对话时生成（见 resetFeedbackIdentity）。没有就用 LicenseManager.deviceID()
    private let kFeedbackDeviceID = "support.deviceId"
    private let kLastSeen = "support.lastSeenId"          // 工单上线前的「全部已读到哪条」，作为各工单已读的下限
    private let kSeenByTicket = "support.seenByTicket"    // [工单 id: 已读到的消息 id]
    private let queue = DispatchQueue(label: "support.chat.store")
    /// 钥匙串读写全在这个串行队列上（不卡主线程）；发消息也先排到这里，保证读到的是找回后的凭证
    private let secretQueue = DispatchQueue(label: "support.chat.secret")

    public private(set) var messages: [SupportMessage] = []
    public private(set) var tickets: [SupportTicket] = []
    private var syncing = false

    public init(defaults: UserDefaults = .standard,
                storeDir: URL? = nil,
                apiBase: String? = nil,
                session: URLSession = .shared,
                secretStore: SecretStoring? = nil) {
        self.defaults = defaults
        self.secretStore = secretStore
        self.session = session
        self.apiBaseOverride = apiBase
        self.storeDir = storeDir ?? VoicePolishConfig.shared.configDirectoryURL.appendingPathComponent("support", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.storeDir, withIntermediateDirectories: true)
        messages = loadMessages()
        tickets = loadTickets()
        if secretStore != nil {
            secretQueue.async { [weak self] in self?.reconcileWithSecretStore() }
        }
    }

    // MARK: - 凭证（偏好设置 + 钥匙串）

    /// 后台队列上跑：偏好设置里没有凭证 → 从钥匙串找回（连同反馈专用标识）；有 → 确保钥匙串里也有一份
    /// （老用户升级到这版后补存）。钥匙串读出错就什么都不做，保持原来的行为。
    private func reconcileWithSecretStore() {
        guard let store = secretStore else { return }
        let local = defaults.string(forKey: kSecret) ?? ""
        if local.isEmpty {
            guard case .found(let saved) = store.lookup(kSecret), !saved.isEmpty else { return }
            let savedID: String?
            switch store.lookup(kFeedbackDeviceID) {
            case .found(let id) where Self.isValidFeedbackDeviceID(id): savedID = id
            case .found, .notFound: savedID = nil
            case .error: return   // 标识读不出来：凭证和标识配不上对，宁可不找回
            }
            defaults.set(saved, forKey: kSecret)
            if let savedID { defaults.set(savedID, forKey: kFeedbackDeviceID) } else { defaults.removeObject(forKey: kFeedbackDeviceID) }
            DispatchQueue.main.async { [weak self] in self?.notify() }
        } else {
            backUp(secret: local, deviceID: defaults.string(forKey: kFeedbackDeviceID), to: store)
        }
    }

    /// 钥匙串里的和当前不一样才写；读出错不写
    private func backUp(secret: String?, deviceID: String?, to store: SecretStoring) {
        for (account, value) in [(kSecret, secret), (kFeedbackDeviceID, deviceID)] {
            let wanted = value ?? ""
            switch store.lookup(account) {
            case .error: continue
            case .found(let saved) where saved == wanted: continue
            case .notFound where wanted.isEmpty: continue
            default: store.set(account, wanted)
            }
        }
    }

    /// 服务器发的新凭证：偏好设置马上写，钥匙串在后台补一份
    func saveSecret(_ secret: String) {
        defaults.set(secret, forKey: kSecret)
        let deviceID = defaults.string(forKey: kFeedbackDeviceID)
        secretQueue.async { [weak self] in
            guard let self, let store = self.secretStore else { return }
            self.backUp(secret: secret, deviceID: deviceID, to: store)
        }
    }

    /// 所有 /support/* 请求用的设备标识：重开过对话就用反馈专用标识，否则照旧用设备标识
    var feedbackDeviceID: String {
        if let id = defaults.string(forKey: kFeedbackDeviceID), Self.isValidFeedbackDeviceID(id) { return id }
        return LicenseManager.shared.deviceID()
    }

    /// 服务器的规矩：^[A-Za-z0-9._:-]{8,128}$
    static func isValidFeedbackDeviceID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9._:-]{8,128}$"#, options: .regularExpression) != nil
    }

    /// 新的反馈专用标识：<设备标识>.<16 位随机十六进制>
    static func makeFeedbackDeviceID(base: String) -> String {
        let suffix = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return "\(base).\(suffix)"
    }

    /// 服务器说凭证不对（403 bad_secret）时的唯一处理入口（主线程）。服务器不能凭设备标识把旧对话交还
    /// （标识不是秘密），所以换一个新的反馈专用标识、当新设备重新开始：清掉本地旧凭证和旧工单缓存
    /// （旧工单以后同步不到，别显示过期状态），钥匙串同步更新。之后的请求一律用新标识、先不带凭证。
    func resetFeedbackIdentity() {
        let newID = Self.makeFeedbackDeviceID(base: LicenseManager.shared.deviceID())
        defaults.set(newID, forKey: kFeedbackDeviceID)
        defaults.removeObject(forKey: kSecret)
        defaults.removeObject(forKey: kLastSeen)
        defaults.removeObject(forKey: kSeenByTicket)
        messages = []
        tickets = []
        saveMessages()
        saveTickets()
        secretQueue.async { [weak self] in
            guard let self, let store = self.secretStore else { return }
            store.set(self.kSecret, nil)
            store.set(self.kFeedbackDeviceID, newID)
        }
        notify()
    }

    /// 测试用：等钥匙串那边排着的读写做完
    func waitForSecretStore() { secretQueue.sync {} }

    // MARK: - 状态

    /// 有没有开始过对话（服务器发过凭证）
    public var hasThread: Bool { (defaults.string(forKey: kSecret) ?? "").isEmpty == false }

    /// 列表顺序：处理中的在前，同状态里新的在前
    public var sortedTickets: [SupportTicket] {
        tickets.sorted { a, b in
            if a.status != b.status { return a.status == .open }
            return a.id > b.id
        }
    }

    public func ticket(id: Int) -> SupportTicket? { tickets.first { $0.id == id } }

    public func messages(inTicket id: Int) -> [SupportMessage] {
        messages.filter { $0.ticketId == id }
    }

    /// 某个工单里开发者的回复还没看过的条数
    public func unreadCount(ticket id: Int) -> Int {
        let seen = max(defaults.integer(forKey: kLastSeen), seenByTicket[String(id)] ?? 0)
        return messages.filter { $0.ticketId == id && $0.role == .admin && $0.id > seen }.count
    }

    /// 侧栏角标：所有工单未读之和（还没同步到工单归属的老消息按老规则算）
    public var unreadCount: Int {
        let floor = defaults.integer(forKey: kLastSeen)
        let orphan = messages.filter { $0.ticketId == nil && $0.role == .admin && $0.id > floor }.count
        return orphan + tickets.reduce(0) { $0 + unreadCount(ticket: $1.id) }
    }

    /// 打开某个工单：把它里面的回复记为已看
    public func markTicketSeen(_ id: Int) {
        guard let maxId = messages(inTicket: id).map(\.id).max(), maxId > (seenByTicket[String(id)] ?? 0) else { return }
        var map = seenByTicket
        map[String(id)] = maxId
        defaults.set(map, forKey: kSeenByTicket)
        notify()
    }

    /// 全部记为已看（老接口，测试和兜底用）
    public func markAllSeen() {
        let maxId = messages.map(\.id).max() ?? 0
        guard maxId > defaults.integer(forKey: kLastSeen) else { return }
        defaults.set(maxId, forKey: kLastSeen)
        notify()
    }

    private var seenByTicket: [String: Int] {
        defaults.dictionary(forKey: kSeenByTicket) as? [String: Int] ?? [:]
    }

    public func imageURL(for message: SupportMessage) -> URL? {
        guard let f = message.localImageFile else { return nil }
        let url = storeDir.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 发送

    public struct Outgoing {
        public var text: String
        public var imageJPEG: Data?        // App 已转码过的 JPEG（去掉了原文件的一切附加内容）
        public var audioM4A: Data?
        public var asrText: String?
        public var polishedText: String?
        public var recentApp: String?
        public var log: String?
        public var deviceName: String
        public var appVersion: String

        public init(text: String, imageJPEG: Data? = nil, audioM4A: Data? = nil,
                    asrText: String? = nil, polishedText: String? = nil,
                    recentApp: String? = nil, log: String? = nil,
                    deviceName: String, appVersion: String) {
            self.text = text; self.imageJPEG = imageJPEG; self.audioM4A = audioM4A
            self.asrText = asrText; self.polishedText = polishedText
            self.recentApp = recentApp; self.log = log
            self.deviceName = deviceName; self.appVersion = appVersion
        }
    }

    /// 纯函数：拼请求体。空内容返回 nil；超大附件直接丢掉（服务器也会拒）。
    /// ticketId：发进哪个工单；category：开新工单时的类型（两者不会同时给）。
    public static func makePayload(_ out: Outgoing, deviceID: String, secret: String?, osVersion: String,
                                   ticketId: Int? = nil, category: SupportTicket.Category? = nil) -> [String: Any]? {
        let text = String(out.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTextChars))
        let image = out.imageJPEG.flatMap { $0.count <= maxImageBytes ? $0 : nil }
        let audio = out.audioM4A.flatMap { $0.count <= maxAudioBytes ? $0 : nil }
        guard !text.isEmpty || image != nil || audio != nil else { return nil }
        var p: [String: Any] = [
            "device_id": deviceID,
            "text": text,
            "app_version": out.appVersion,
            "os_version": osVersion,
            "device_name": out.deviceName,
        ]
        if let secret, !secret.isEmpty { p["secret"] = secret }
        if let ticketId { p["ticket_id"] = ticketId }
        if let category { p["category"] = category.rawValue }
        if let image { p["image_b64"] = image.base64EncodedString() }
        if let audio { p["audio_b64"] = audio.base64EncodedString() }
        if let a = out.asrText, !a.isEmpty { p["asr_text"] = String(a.prefix(10_000)) }
        if let o = out.polishedText, !o.isEmpty { p["polished_text"] = String(o.prefix(10_000)) }
        if let r = out.recentApp, !r.isEmpty { p["recent_app"] = String(r.prefix(128)) }
        if let l = out.log, !l.isEmpty { p["log"] = String(l.suffix(maxLogChars)) }
        return p
    }

    /// 开新工单：out.text 是问题描述（必填）。新设备的第一张工单服务器不收附件（attachmentsDropped=true），调用方再补发一条。
    public func createTicket(category: SupportTicket.Category, _ out: Outgoing,
                             completion: @escaping (Result<(ticket: SupportTicket, attachmentsDropped: Bool), SupportChatError>) -> Void) {
        openTicket(category: category, out, allowReopen: true) { result in
            completion(result.map { ($0.ticket, $0.attachmentsDropped) })
        }
    }

    /// allowReopen：凭证不对时换新标识重开一次（重开的那次不再重开，防死循环）
    private func openTicket(category: SupportTicket.Category, _ out: Outgoing, allowReopen: Bool,
                            completion: @escaping (Result<(ticket: SupportTicket, message: SupportMessage, attachmentsDropped: Bool), SupportChatError>) -> Void) {
        guard !out.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DispatchQueue.main.async { completion(.failure(.network("先描述一下遇到的问题"))) }
            return
        }
        post(path: "/support/tickets/create", out: out, ticketId: nil, category: category) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(.credentialRejected) where allowReopen:
                // 新标识＝新设备：这条不带凭证重发，服务器发新凭证；带的附件会被丢（attachments_dropped），界面那边会补发
                self.resetFeedbackIdentity()
                self.openTicket(category: category, out, allowReopen: false, completion: completion)
            case .failure(let e): completion(.failure(e))
            case .success(let (json, msg)):
                guard let t = (json["ticket"] as? [String: Any]).flatMap(SupportTicket.init(json:)) else {
                    completion(.failure(.network("服务器返回格式不对")))
                    return
                }
                self.upsertTickets([t])
                self.append([msg])
                completion(.success((t, msg, json["attachments_dropped"] as? Bool ?? false)))
            }
        }
    }

    /// 往某个处理中的工单里发消息
    public func send(_ out: Outgoing, ticketId: Int, completion: @escaping (Result<SupportMessage, SupportChatError>) -> Void) {
        post(path: "/support/send", out: out, ticketId: ticketId, category: nil) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(.credentialRejected):
                self.reopenAndResend(out, completion: completion)
            case .failure(let e):
                if e == .ticketClosed { self.sync() }   // 工单在别处被结束了：拉一下，让页面变成只读
                completion(.failure(e))
            case .success(let (_, msg)):
                self.append([msg])
                completion(.success(msg))
            }
        }
    }

    /// 在旧工单里回复时凭证不对：旧工单属于旧标识、以后同步不到了，这条话换新标识开成一个新工单发出去；
    /// 新标识第一条只收文字，带的截图 / 录音紧跟着补发进新工单。只重开这一次。
    private func reopenAndResend(_ out: Outgoing, completion: @escaping (Result<SupportMessage, SupportChatError>) -> Void) {
        resetFeedbackIdentity()
        guard !out.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(.network("反馈记录需要重新开始，请先写一句话说明问题再发，截图和录音可以随后附上")))
            return
        }
        openTicket(category: .other, out, allowReopen: false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let created) where created.attachmentsDropped && (out.imageJPEG != nil || out.audioM4A != nil):
                var followUp = out
                followUp.text = ""
                followUp.asrText = nil; followUp.polishedText = nil; followUp.log = nil   // 这些已随第一条发出
                self.post(path: "/support/send", out: followUp, ticketId: created.ticket.id, category: nil) { [weak self] r2 in
                    switch r2 {
                    case .success(let (_, msg2)):
                        self?.append([msg2])
                        completion(.success(created.message))
                    case .failure:
                        completion(.failure(.network("文字已发出，截图 / 录音没发成功，可以再附上发一次")))
                    }
                }
            case .success(let created):
                completion(.success(created.message))
            }
        }
    }

    private func post(path: String, out: Outgoing, ticketId: Int?, category: SupportTicket.Category?,
                      completion: @escaping (Result<([String: Any], SupportMessage), SupportChatError>) -> Void) {
        // 排到钥匙串队列后面：刚启动时凭证可能还在从钥匙串找回，别拿着空凭证去撞「凭证不对」
        secretQueue.async { [weak self] in
            self?.performPost(path: path, out: out, ticketId: ticketId, category: category, completion: completion)
        }
    }

    private func performPost(path: String, out: Outgoing, ticketId: Int?, category: SupportTicket.Category?,
                             completion: @escaping (Result<([String: Any], SupportMessage), SupportChatError>) -> Void) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let deviceID = feedbackDeviceID
        guard let payload = Self.makePayload(out, deviceID: deviceID, secret: defaults.string(forKey: kSecret),
                                             osVersion: "\(os.majorVersion).\(os.minorVersion)",
                                             ticketId: ticketId, category: category) else {
            DispatchQueue.main.async { completion(.failure(.empty)) }
            return
        }
        guard let url = URL(string: apiBase + path) else {
            DispatchQueue.main.async { completion(.failure(.network("地址错误"))) }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = (payload["image_b64"] != nil || payload["audio_b64"] != nil) ? 90 : 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                // 系统原话（localizedDescription）是英文 / 带服务器地址，换成同一套中文短句
                let reason = UserFacingError.networkMessage(for: error) ?? "网络不通"
                DispatchQueue.main.async { completion(.failure(.network(reason))) }
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard code == 200, let json, let id = json["id"] as? Int else {
                DispatchQueue.main.async { completion(.failure(Self.classify(code: code, json: json))) }
                return
            }
            if let secret = json["secret"] as? String, !secret.isEmpty {
                self.saveSecret(secret)
            }
            let dropped = json["attachments_dropped"] as? Bool ?? false
            var localFile: String?
            if let image = out.imageJPEG, !dropped {
                localFile = "img-\(id).jpg"
                try? image.write(to: self.storeDir.appendingPathComponent(localFile!), options: .atomic)
            }
            let msg = SupportMessage(id: id, role: .user, text: payload["text"] as? String ?? "",
                                     hasImage: out.imageJPEG != nil && !dropped, hasAudio: out.audioM4A != nil && !dropped,
                                     createdAt: json["created_at"] as? String ?? ISO8601DateFormatter().string(from: Date()),
                                     localImageFile: localFile,
                                     ticketId: json["ticket_id"] as? Int ?? ticketId)
            DispatchQueue.main.async { completion(.success((json, msg))) }
        }.resume()
    }

    /// 纯函数：服务器错误 → 给用户看的错误。服务器的中文提示优先。
    public static func classify(code: Int, json: [String: Any]?) -> SupportChatError {
        switch json?["code"] as? String {
        case "blocked": return .blocked
        case "body_too_large", "bad_image": return .tooLarge
        case "ticket_closed": return .ticketClosed
        // 凭证不对。老服务器用笼统的 forbidden（用户端接口里只在凭证不对时用），一并认，不受发版先后影响
        case "bad_secret": return .credentialRejected
        case "forbidden" where code == 403: return .credentialRejected
        default:
            if let msg = json?["error"] as? String, !msg.isEmpty, code >= 400, code < 500 { return .network(msg) }
            return .network(code == 0 ? "网络不通" : "服务器返回 \(code)")
        }
    }

    // MARK: - 拉新回复

    /// 去服务器拿新消息和全部工单（状态随时会变）。没开始过对话直接返回。
    /// 本机还有没归属工单的老消息（工单上线前缓存的）时，从头拉一遍把归属补上。
    public func sync(completion: ((Bool) -> Void)? = nil) {
        guard hasThread, !syncing, let secret = defaults.string(forKey: kSecret),
              let url = URL(string: apiBase + "/support/sync") else {
            DispatchQueue.main.async { completion?(false) }
            return
        }
        syncing = true
        let after = messages.contains { $0.ticketId == nil } ? 0 : (messages.map(\.id).max() ?? 0)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": feedbackDeviceID, "secret": secret, "after_id": after,
        ])
        session.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let root = code == 200 ? json : nil
            let incoming = (root?["messages"] as? [[String: Any]] ?? []).compactMap(Self.parseMessage)
            let ticketList = (root?["tickets"] as? [[String: Any]])?.compactMap(SupportTicket.init(json:))
            let rejected = code != 200 && Self.classify(code: code, json: json) == .credentialRejected
            DispatchQueue.main.async {
                self.syncing = false
                // 拉新回复时凭证不对：只换标识、清凭证，等用户下次发消息再开新对话
                if rejected { self.resetFeedbackIdentity() }
                if let ticketList { self.replaceTickets(ticketList) }
                if !incoming.isEmpty { self.append(incoming) }
                completion?(code == 200)
            }
        }.resume()
    }

    static func parseMessage(_ m: [String: Any]) -> SupportMessage? {
        guard let id = m["id"] as? Int, let roleRaw = m["role"] as? String,
              let role = SupportMessage.Role(rawValue: roleRaw) else { return nil }
        return SupportMessage(id: id, role: role, text: m["text"] as? String ?? "",
                              hasImage: m["has_image"] as? Bool ?? false,
                              hasAudio: m["has_audio"] as? Bool ?? false,
                              createdAt: m["created_at"] as? String ?? "",
                              ticketId: m["ticket_id"] as? Int)
    }

    // MARK: - 本机缓存

    private var apiBase: String {
        apiBaseOverride ?? defaults.string(forKey: "license.apiBase") ?? FeedbackService.defaultAPIBase
    }

    private var storeURL: URL { storeDir.appendingPathComponent("support.json") }
    private var ticketsURL: URL { storeDir.appendingPathComponent("support-tickets.json") }

    private func loadMessages() -> [SupportMessage] {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([SupportMessage].self, from: data) else { return [] }
        return list.sorted { $0.id < $1.id }
    }

    private func loadTickets() -> [SupportTicket] {
        guard let data = try? Data(contentsOf: ticketsURL),
              let list = try? JSONDecoder().decode([SupportTicket].self, from: data) else { return [] }
        return list
    }

    /// 合并消息：同 id 用新的，但保留本机截图缓存（服务器不回传图）
    func append(_ new: [SupportMessage]) {
        var byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for var m in new {
            if m.localImageFile == nil { m.localImageFile = byId[m.id]?.localImageFile }
            byId[m.id] = m
        }
        messages = byId.values.sorted { $0.id < $1.id }
        saveMessages()
        notify()
    }

    private func saveMessages() {
        let snapshot = messages
        let url = storeURL
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func replaceTickets(_ list: [SupportTicket]) {
        guard list != tickets else { return }
        tickets = list
        saveTickets()
        notify()
    }

    private func upsertTickets(_ list: [SupportTicket]) {
        var byId = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
        for t in list { byId[t.id] = t }
        tickets = Array(byId.values)
        saveTickets()
        notify()
    }

    private func saveTickets() {
        let snapshot = tickets
        let url = ticketsURL
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

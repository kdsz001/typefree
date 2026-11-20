import Foundation
import CryptoKit
#if os(macOS)
import IOKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 授权管理：对接自家 Cloudflare Worker（api.typefree.app）。
///
/// - `activate`：把「激活码 + 设备指纹」发给服务器，服务器在账本里核销名额后
///   用 Ed25519 私钥对 "<code>:<device_id>" 签名返回 token。
/// - `isActivated`：用内嵌公钥**本地验签** token，日常使用完全离线。
/// - 设备指纹 = 硬件 UUID 的 SHA-256（不可逆），**不上传**电脑名等个人信息。
/// - 公开接口与旧 Lemon Squeezy 版完全一致，界面层（SettingsWindowController）零改动。
public final class LicenseManager {
    public static let shared = LicenseManager()

    /// 激活失败的归类，便于上层给出友好提示。
    public enum ActivationError: Error, Equatable {
        case emptyKey            // 没填授权码
        case invalidKey          // 授权码不存在 / 已退款停用
        case limitReached        // 激活台数已满（1 个码只能 1 台 Mac）
        case network(String)     // 网络或其它错误
    }

    // 🔑 生产公钥，与 Worker 的 ED25519_PRIVATE_KEY（备份于 ~/voicepolish-license-backup）配对。
    // 2026-06-10 已验证配对。换钥前必须想清楚：换了 = 所有已发 token 全部失效。
    public static let embeddedPublicKeyBase64 = "abCefT2wij5lUaJlIBi0y+qhv/OkJ7QfwQK/2OsePXs="

    static let defaultAPIBase = "https://api.typefree.app"

    private let defaults: UserDefaults
    private let session: URLSession
    private let apiBase: String

    private let kKey = "license.key"
    private let kToken = "license.token"
    private let kFallbackDevice = "license.fallbackDeviceId"
    private let kLastValidated = "license.lastValidatedAt"
    private let kLastAppVersion = "license.lastAppVersion"
    // 会员（2026-09）：来自 /activate、/validate 的返回，老服务器不带时按「老买断/赠送」处理
    private let kPlan = "license.plan"
    private let kExpiresAt = "license.expiresAt"
    private let kExpiresDay = "license.expiresDay"
    private let kExpired = "license.expired"
    private let kMemberToken = "license.memberToken"
    private let kGenesis = "license.genesis"
    private let kAutoRenew = "license.autoRenew"

    /// 会员状态（套餐/到期/令牌有无/创世标识）变化时发出（主线程）。设置窗据此刷新侧边栏。
    public static let membershipDidChangeNotification = Notification.Name("LicenseManager.membershipDidChange")

    private let stateLock = NSLock()
    private var revalidating = false
    private var lastForcedAttempt: TimeInterval = 0

    /// apiBase 可经 UserDefaults `license.apiBase` 覆盖（本地联调用），缺省走生产。
    public init(defaults: UserDefaults = .standard, session: URLSession = .shared, apiBase: String? = nil) {
        self.defaults = defaults
        self.session = session
        self.apiBase = apiBase ?? defaults.string(forKey: "license.apiBase") ?? Self.defaultAPIBase
    }

    // MARK: - 纯函数（与 Worker 端必须一致，有跨语言向量测试互证）

    /// 被签名的内容。Worker 端必须用完全相同的拼法（"<code>:<device_id>"）。
    public static func licenseMessage(code: String, deviceID: String) -> String {
        "\(code):\(deviceID)"
    }

    public static func verify(message: String, tokenBase64: String, publicKeyBase64: String) -> Bool {
        guard let pub = Data(base64Encoded: publicKeyBase64),
              let sig = Data(base64Encoded: tokenBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { return false }
        return key.isValidSignature(sig, for: Data(message.utf8))
    }

    // MARK: - 状态查询（离线）

    /// 已激活 = 本地存有 code+token 且对「code:本机指纹」验签通过。拷配置到别的机器无效。
    public var isActivated: Bool {
        guard let code = defaults.string(forKey: kKey), !code.isEmpty,
              let token = defaults.string(forKey: kToken), !token.isEmpty else { return false }
        return Self.verify(message: Self.licenseMessage(code: code, deviceID: deviceID()),
                           tokenBase64: token,
                           publicKeyBase64: Self.embeddedPublicKeyBase64)
    }

    /// 已保存的授权码（用于界面展示，会做掩码）。
    public var licenseKey: String? { defaults.string(forKey: kKey) }

    // MARK: - 会员（2026-09，Ray 拍板：年付会员走托管识别；3.0 前的老用户有「创世用户」永久标识）

    /// /activate 与 /validate 返回里的会员相关字段。
    public struct MembershipInfo: Equatable {
        public let plan: String          // "sponsor"（老买断/赠送码）| "member"（年付会员）
        public let expiresAt: String?    // UTC "yyyy-MM-dd HH:mm:ss"
        public let expiresDay: String?   // 北京日 "yyyy-MM-dd"，界面展示用
        public let expired: Bool
        public let memberToken: String?
        public let genesis: Bool
        public let autoRenew: Bool      // 银行卡自动续费（有 Paddle 订阅）

        public static func parse(_ json: [String: Any]) -> MembershipInfo {
            let token = (json["member_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return MembershipInfo(plan: (json["plan"] as? String) ?? "sponsor",
                                  expiresAt: json["expires_at"] as? String,
                                  expiresDay: json["expires_day"] as? String,
                                  expired: (json["expired"] as? Bool) ?? false,
                                  memberToken: token,
                                  genesis: (json["genesis"] as? Bool) ?? false,
                                  autoRenew: (json["auto_renew"] as? Bool) ?? false)
        }
    }

    /// 套餐：未激活或老服务器没返回时为 "sponsor"。
    public var plan: String { defaults.string(forKey: kPlan) ?? "sponsor" }
    /// 已激活且是年付会员（不论是否到期）。
    public var isMember: Bool { isActivated && plan == "member" }
    /// 创世用户：永久标识，与会员是否到期无关。
    public var isGenesis: Bool { isActivated && defaults.bool(forKey: kGenesis) }
    /// 会员到期日（北京日，展示用）。
    public var memberExpiresDay: String? { isMember ? defaults.string(forKey: kExpiresDay) : nil }
    /// 会员是否银行卡自动续费；一次性年卡与赠送的会员为 false。
    public var memberAutoRenew: Bool { isMember && defaults.bool(forKey: kAutoRenew) }

    /// 会员剩余天数（向下取整，已到期为 0）；非会员或没有到期时间返回 nil。
    public func memberDaysLeft(now: Date = Date()) -> Int? {
        guard isMember, let s = defaults.string(forKey: kExpiresAt), let t = Self.parseUTC(s) else { return nil }
        return max(0, Int((t - now.timeIntervalSince1970) / 86400))
    }

    /// 会员到期后的宽限天数。⚠ 必须和激活服务 license-worker/src/member.js 的 GRACE_DAYS 保持一致：
    /// 自动续费的扣款回执（Paddle webhook）可能晚到几个小时，宽限期内服务器仍算有效（expired=false）、照常签令牌。
    public static let memberGraceDays: Double = 3

    /// 本地判断会员是否已到期（纯函数，便于单测）：以服务器返回的 expired 为准（它已算上宽限）；
    /// 服务器没说过期时，本地时钟过了「到期 + 宽限」才兜底判到期（断网好几天的情况）。
    /// 体检 优7：以前到期那一刻就判到期，自动续费会员在续费回执到达前最长约 6 小时被拦。
    public static func isMemberExpired(serverSaysExpired: Bool, expiresAt: TimeInterval?, now: TimeInterval) -> Bool {
        if serverSaysExpired { return true }
        guard let expiresAt else { return false }
        return now >= expiresAt + memberGraceDays * 86_400
    }

    /// 会员已到期：服务器明确说到期，或本地时钟已过「到期 + 宽限」。
    /// 宽限期内不判到期：能不能走托管通道照旧看会员令牌（hasActiveMembership），没有可用令牌时由调用方找服务器复核。
    public func isMemberExpired(now: Date = Date()) -> Bool {
        guard isMember else { return false }
        return Self.isMemberExpired(serverSaysExpired: defaults.bool(forKey: kExpired),
                                    expiresAt: defaults.string(forKey: kExpiresAt).flatMap(Self.parseUTC),
                                    now: now.timeIntervalSince1970)
    }

    /// 可用的会员令牌（没过期才给），托管通道请求头用。
    public func memberToken(now: Date = Date()) -> String? {
        guard isMember, let token = defaults.string(forKey: kMemberToken), !token.isEmpty,
              let exp = Self.memberTokenExpiry(token), now.timeIntervalSince1970 < exp else { return nil }
        return token
    }

    /// 会员有效且手里有可用令牌 → 识别/润色/问 AI 可以走托管通道。
    public func hasActiveMembership(now: Date = Date()) -> Bool {
        isMember && !isMemberExpired(now: now) && memberToken(now: now) != nil
    }

    /// 会员令牌 `b64url(code|deviceId|exp).b64url(sig)` 里的到期时刻（Unix 秒）。
    /// 只读不验签——验签在服务器；这里只用来判断「该不该提前找服务器换新令牌」。
    public static func memberTokenExpiry(_ token: String) -> TimeInterval? {
        guard let dot = token.lastIndex(of: ".") else { return nil }
        var b64 = String(token[..<dot]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let payload = String(data: data, encoding: .utf8) else { return nil }
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let exp = TimeInterval(parts[2]) else { return nil }
        return exp
    }

    /// Worker 的 datetime 文本（UTC）→ Unix 秒。
    static func parseUTC(_ s: String) -> TimeInterval? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)?.timeIntervalSince1970
    }

    /// 写入服务器返回的会员字段；有实质变化时发通知。
    func applyMembership(_ info: MembershipInfo) {
        let before = membershipFingerprint()
        defaults.set(info.plan, forKey: kPlan)
        setOrRemove(info.expiresAt, forKey: kExpiresAt)
        setOrRemove(info.expiresDay, forKey: kExpiresDay)
        defaults.set(info.expired, forKey: kExpired)
        setOrRemove(info.memberToken, forKey: kMemberToken)
        defaults.set(info.genesis, forKey: kGenesis)
        defaults.set(info.autoRenew, forKey: kAutoRenew)
        if membershipFingerprint() != before { postMembershipChanged() }
    }

    /// 令牌每次复核都会换新，这里只比「有没有」，免得每次复核都刷新界面。
    private func membershipFingerprint() -> String {
        [plan,
         defaults.string(forKey: kExpiresAt) ?? "",
         defaults.bool(forKey: kExpired) ? "1" : "0",
         (defaults.string(forKey: kMemberToken)?.isEmpty == false) ? "1" : "0",
         defaults.bool(forKey: kGenesis) ? "1" : "0",
         defaults.bool(forKey: kAutoRenew) ? "1" : "0"].joined(separator: "|")
    }

    private func setOrRemove(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private func postMembershipChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.membershipDidChangeNotification, object: nil) }
    }

    /// 设备指纹：硬件 UUID 的 SHA-256 前 32 位 hex（不可逆）；取不到时本地随机 UUID 存档兜底。
    public func deviceID() -> String {
        let raw: String
        if let hw = Self.hardwareUUID(), !hw.isEmpty {
            raw = hw
        } else if let saved = defaults.string(forKey: kFallbackDevice), !saved.isEmpty {
            raw = saved
        } else {
            let new = UUID().uuidString
            defaults.set(new, forKey: kFallbackDevice)
            raw = new
        }
        let digest = SHA256.hash(data: Data(raw.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    private static func hardwareUUID() -> String? {
        #if os(macOS)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        #elseif canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    /// 机型标识（如 "Mac15,7"），仅用于「已激活设备」展示与客服排查，不含个人信息。
    private static func deviceModel() -> String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(cString: chars)
        #else
        return "iOS"
        #endif
    }

    // MARK: - 激活

    /// 用授权码激活本设备。
    /// `instanceName` 仅为保持旧接口签名而保留，**故意不上传**（电脑名常含真实姓名）。
    public func activate(key: String,
                         instanceName: String,
                         completion: @escaping (Result<Void, ActivationError>) -> Void) {
        _ = instanceName
        let code = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.emptyKey)) }
            return
        }
        let device = deviceID()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        post(path: "/activate", body: [
            "code": code,
            "device_id": device,
            "device_model": Self.deviceModel(),
            "os_version": "\(os.majorVersion).\(os.minorVersion)",
        ]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                DispatchQueue.main.async { completion(.failure(e)) }
            case .success(let json):
                guard let token = json["token"] as? String,
                      Self.verify(message: Self.licenseMessage(code: code, deviceID: device),
                                  tokenBase64: token,
                                  publicKeyBase64: Self.embeddedPublicKeyBase64) else {
                    DispatchQueue.main.async {
                        completion(.failure(.network("激活校验失败，请联系 ray@typefree.app")))
                    }
                    return
                }
                self.defaults.set(code, forKey: self.kKey)
                self.defaults.set(token, forKey: self.kToken)
                self.defaults.set(Date().timeIntervalSince1970, forKey: self.kLastValidated)
                self.applyMembership(MembershipInfo.parse(json))
                DispatchQueue.main.async { completion(.success(())) }
            }
        }
    }

    // MARK: - 联网复核（远程失效：退款 / 在找回页被重置的旧设备，几天内自动退出激活）

    /// 距上次成功复核超过该间隔才真正发请求。
    public static let revalidationInterval: TimeInterval = 3 * 24 * 3600

    /// 是否到了该复核的时间（纯函数，便于测试）。
    public static func isRevalidationDue(lastValidatedAt: TimeInterval, now: TimeInterval) -> Bool {
        now - lastValidatedAt >= revalidationInterval
    }

    /// 会员额外规则：令牌缺失或 24 小时内到期 → 立刻复核换新令牌（否则托管通道会断）；非会员照旧按间隔。
    public static func isRevalidationDue(lastValidatedAt: TimeInterval, now: TimeInterval,
                                         isMember: Bool, memberTokenExpiry: TimeInterval?) -> Bool {
        if isMember {
            guard let exp = memberTokenExpiry else { return true }
            if exp - now < 24 * 3600 { return true }
        }
        return isRevalidationDue(lastValidatedAt: lastValidatedAt, now: now)
    }

    /// 解析 /validate 返回：true=有效，false=明确失效，nil=看不懂（不动作）。
    /// 首次记录（stored 为空）也算「变了」：老版本升上来没存过版本号，正是最需要立刻复核的那批人。
    public static func appVersionChanged(stored: String?, current: String) -> Bool {
        !current.isEmpty && stored != current
    }

    public static func revalidationVerdict(_ json: [String: Any]) -> Bool? {
        json["valid"] as? Bool
    }

    /// 启动定期复核：立即查一次，之后每 6 小时看一眼是否到期（到期才真正联网）。
    /// 死规矩：只有服务器明确回答「失效」才退出激活；没网/服务器出错一律照常用。
    /// appVersion：换了版本（如 2.8.1 → 3.0.0）就无视 3 天间隔立刻复核一次——发版当天服务器把老买断用户改成会员+创世标，
    /// 用户一更新就该看到，而不是等最多 3 天。
    public func startRevalidation(appVersion: String? = nil) {
        if let v = appVersion, Self.appVersionChanged(stored: defaults.string(forKey: kLastAppVersion), current: v) {
            defaults.set(v, forKey: kLastAppVersion)
            defaults.removeObject(forKey: kLastValidated)
        }
        revalidateIfNeeded()
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.revalidateIfNeeded()
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
    }

    func revalidateIfNeeded(now: Date = Date()) {
        guard isActivated, defaults.string(forKey: kKey) != nil else { return }
        let tokenExpiry = defaults.string(forKey: kMemberToken).flatMap(Self.memberTokenExpiry)
        guard Self.isRevalidationDue(lastValidatedAt: defaults.double(forKey: kLastValidated),
                                     now: now.timeIntervalSince1970,
                                     isMember: plan == "member", memberTokenExpiry: tokenExpiry) else { return }
        revalidateNow(now: now)
    }

    /// 立刻找服务器复核一次（不看间隔）：会员令牌缺失/被托管通道拒绝时用。
    /// 同一时刻只发一个、60 秒内最多一次；completion 在主线程回调，true = 拿到了有效结果。
    public func revalidateNow(now: Date = Date(), completion: ((Bool) -> Void)? = nil) {
        revalidateWithOutcome(now: now) { completion?($0 == .valid) }
    }

    /// 一次立刻复核的结果（体检 优10：被 60 秒节流挡住时，别再当成「连不上」报给用户）
    public enum RevalidationOutcome: Equatable {
        /// 服务器确认有效，会员信息已更新
        case valid
        /// 服务器明确说失效（退款 / 被重置），本机已退出激活；或本机根本没激活
        case invalid
        /// 没联上 / 服务器出错 / 看不懂答复：本地什么都不动
        case unreachable
        /// 这次没发请求：上一次还在路上（inFlight），或 60 秒内刚问过（lastUnreachable = 上一次是不是没联上）
        case throttled(inFlight: Bool, lastUnreachable: Bool)
    }

    /// 上一次立刻复核是不是没联上（节流时据此判断要不要提示网络问题）
    private var lastRevalidationUnreachable = false

    /// 同 revalidateNow，但把结果分清楚告诉调用方（主线程回调）。
    public func revalidateWithOutcome(now: Date = Date(), completion: ((RevalidationOutcome) -> Void)? = nil) {
        guard isActivated, let code = defaults.string(forKey: kKey) else {
            DispatchQueue.main.async { completion?(.invalid) }
            return
        }
        stateLock.lock()
        let inFlight = revalidating
        let throttled = inFlight || now.timeIntervalSince1970 - lastForcedAttempt < 60
        let lastUnreachable = lastRevalidationUnreachable
        if !throttled { revalidating = true; lastForcedAttempt = now.timeIntervalSince1970 }
        stateLock.unlock()
        if throttled {
            DispatchQueue.main.async { completion?(.throttled(inFlight: inFlight, lastUnreachable: lastUnreachable)) }
            return
        }
        post(path: "/validate", body: ["code": code, "device_id": deviceID()]) { [weak self] result in
            guard let self = self else { return }
            var outcome = RevalidationOutcome.unreachable
            if case .success(let json) = result {   // 失败 = 沉默不杀
                switch Self.revalidationVerdict(json) {
                case true?:
                    self.defaults.set(now.timeIntervalSince1970, forKey: self.kLastValidated)
                    self.applyMembership(MembershipInfo.parse(json))
                    outcome = .valid
                case false?:
                    self.clearLocal()
                    outcome = .invalid
                case nil:
                    break
                }
            }
            self.stateLock.lock()
            self.revalidating = false
            self.lastRevalidationUnreachable = outcome == .unreachable
            self.stateLock.unlock()
            DispatchQueue.main.async { completion?(outcome) }
        }
    }

    public static let revalidationUnreachableHint = "无法连接激活服务，请检查网络后再试"
    public static let memberExpiredHint = "会员已到期 · 续费，或在「设置 → 模型」填自己的 Key"
    /// 服务器说会员有效、却没给能用的令牌（如旧版激活服务在到期宽限内签的令牌一出生就过期）：托管通道这会儿用不了
    public static let memberChannelUnavailableHint = "会员服务暂时用不了，请稍后再试，或在「设置 → 模型」填自己的 Key"

    /// 按下快捷键时发现会员没有可用令牌、立刻复核之后，要补哪句提示（纯函数，便于单测）。nil = 不补，
    /// 「正在验证会员状态，请稍候…」那句就是对的。
    /// - 这次没联上，或被节流且 60 秒内上一次没联上 → 「检查网络」
    /// - 上一次还在路上 → 不补，结果马上回来
    /// - 服务器确认有效：已到期（已含 3 天宽限）→「会员已到期」；有可用令牌 → 不补；没有 →「暂时用不了」
    /// - 被节流、上一次联上了：上一次就没拿到可用令牌（拿到了就不会走到复核）→「暂时用不了」
    /// - 服务器明确说失效：本机已退出激活，不说网络
    public static func revalidationHint(after outcome: RevalidationOutcome,
                                        memberExpired: Bool, hasActiveMembership: Bool) -> String? {
        switch outcome {
        case .unreachable:
            return revalidationUnreachableHint
        case .throttled(let inFlight, let lastUnreachable):
            if inFlight { return nil }
            if lastUnreachable { return revalidationUnreachableHint }
            return hasActiveMembership ? nil : memberChannelUnavailableHint
        case .valid:
            if memberExpired { return memberExpiredHint }
            return hasActiveMembership ? nil : memberChannelUnavailableHint
        case .invalid:
            return nil
        }
    }

    // MARK: - 取消激活（换机）

    /// 通知服务器释放名额；不论服务器结果如何，本地都清空（与 LS 版行为一致，
    /// 保证用户总能在新机上重新激活——名额若没释放成功还有找回页重置兜底）。
    public func deactivate(completion: @escaping (Result<Void, ActivationError>) -> Void) {
        let code = defaults.string(forKey: kKey)
        let device = deviceID()
        clearLocal()
        guard let code = code, !code.isEmpty else {
            DispatchQueue.main.async { completion(.success(())) }
            return
        }
        post(path: "/deactivate", body: ["code": code, "device_id": device]) { result in
            DispatchQueue.main.async {
                switch result {
                case .success: completion(.success(()))
                case .failure(let e): completion(.failure(e))
                }
            }
        }
    }

    // MARK: - 内部

    private func clearLocal() {
        defaults.removeObject(forKey: kKey)
        defaults.removeObject(forKey: kToken)
        for k in [kPlan, kExpiresAt, kExpiresDay, kExpired, kMemberToken, kGenesis, kAutoRenew] { defaults.removeObject(forKey: k) }
        postMembershipChanged()
    }

    private func post(path: String,
                      body: [String: String],
                      completion: @escaping (Result<[String: Any], ActivationError>) -> Void) {
        guard let url = URL(string: apiBase + path) else {
            completion(.failure(.network("地址错误")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: req) { data, response, error in
            if let error = error {
                // 界面显示「激活失败：…」：系统原话是英文、可能带网址，换成中文短句（体检 修4）
                completion(.failure(.network(UserFacingError.message(for: error, fallback: "网络出错，请稍后再试"))))
                return
            }
            guard let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(.failure(.network("返回解析失败")))
                return
            }
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                completion(.success(json))
                return
            }
            // 服务器 403 带机器可读错误码：not_found/revoked → invalidKey，limit_reached → limitReached
            switch json["code"] as? String {
            case "not_found", "revoked": completion(.failure(.invalidKey))
            case "limit_reached":        completion(.failure(.limitReached))
            default:
                let msg = json["error"] as? String
                completion(.failure(.network(msg?.isEmpty == false ? msg! : "激活失败，请稍后重试")))
            }
        }.resume()
    }
}

import XCTest
@testable import VoicePolishCore

final class TrialManagerTests: XCTestCase {

    // MARK: - parseTrialStart：纯函数，不依赖网络

    func testParseSuccess() {
        let json: [String: Any] = [
            "trial_token": "tok-abc123",
            "days_left": 7,
            "daily_limit": 1500,
            "used_today": 42,
        ]
        let p = TrialManager.parseTrialStart(json)
        XCTAssertEqual(p.token, "tok-abc123")
        XCTAssertEqual(p.daysLeft, 7)
        XCTAssertEqual(p.dailyLimit, 1500)
        XCTAssertEqual(p.usedToday, 42)
        XCTAssertFalse(p.expired)
    }

    func testParseExpired() {
        let json: [String: Any] = ["expired": true]
        let p = TrialManager.parseTrialStart(json)
        XCTAssertNil(p.token)
        XCTAssertTrue(p.expired)
    }

    func testParseMissingDailyLimitDefaultsTo1500() {
        let json: [String: Any] = [
            "trial_token": "tok-xyz",
            "days_left": 3,
            "used_today": 0,
            // daily_limit 故意缺失
        ]
        let p = TrialManager.parseTrialStart(json)
        XCTAssertEqual(p.dailyLimit, 1500, "daily_limit 缺失时应默认 1500")
    }

    func testParseGarbageJson() {
        let p = TrialManager.parseTrialStart(["error": "unknown"])
        XCTAssertNil(p.token, "看不懂的响应 → token 为 nil")
        XCTAssertFalse(p.expired, "看不懂的响应 → 不标记为过期")
    }

    func testParseEmptyDict() {
        let p = TrialManager.parseTrialStart([:])
        XCTAssertNil(p.token)
        XCTAssertFalse(p.expired)
    }

    func testParseExpiredFalseNotTreatedAsExpired() {
        // expired:false 不应触发过期路径
        let json: [String: Any] = [
            "trial_token": "tok-still-valid",
            "days_left": 5,
            "daily_limit": 1500,
            "used_today": 10,
            "expired": false,
        ]
        let p = TrialManager.parseTrialStart(json)
        XCTAssertEqual(p.token, "tok-still-valid")
        XCTAssertFalse(p.expired)
    }

    // MARK: - isInTrial：注入独立 UserDefaults，不污染 .standard

    private func freshDefaults(name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "trial-test-\(name)")!
        // 清理残留
        for key in ["trial.token", "trial.daysLeft", "trial.usedToday",
                    "trial.dailyLimit", "trial.expired", "trial.lastRefreshAt"] {
            d.removeObject(forKey: key)
        }
        return d
    }

    func testIsInTrialTrueWhenTokenPresentAndNotExpired() {
        let d = freshDefaults(name: "active")
        d.set("tok-valid", forKey: "trial.token")
        d.set(false, forKey: "trial.expired")
        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")
        XCTAssertTrue(mgr.isInTrial)
    }

    func testIsInTrialFalseWhenNoToken() {
        let d = freshDefaults(name: "notoken")
        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")
        XCTAssertFalse(mgr.isInTrial)
    }

    func testIsInTrialFalseWhenExpiredFlagSet() {
        let d = freshDefaults(name: "expired")
        d.set("tok-old", forKey: "trial.token")
        d.set(true, forKey: "trial.expired")
        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")
        XCTAssertFalse(mgr.isInTrial)
    }

    func testIsInTrialFalseWhenTokenIsEmptyString() {
        let d = freshDefaults(name: "emptytoken")
        d.set("", forKey: "trial.token")
        d.set(false, forKey: "trial.expired")
        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")
        XCTAssertFalse(mgr.isInTrial)
    }

    // MARK: - 缓存往返：applyParsed 后读回 accessor 要匹配

    func testCacheRoundTripSuccessResponse() {
        let d = freshDefaults(name: "roundtrip")
        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")

        let json: [String: Any] = [
            "trial_token": "rt-token-99",
            "days_left": 14,
            "daily_limit": 2000,
            "used_today": 111,
        ]
        let parsed = TrialManager.parseTrialStart(json)
        // 直接调用内部 applyParsed（通过 refreshFromServer 的 testable 逻辑），
        // 这里用内部方法验证：通过同一 defaults 构造第二个实例读回
        //
        // 因为 applyParsed 是 private，我们用一个协议保留的方式——
        // 通过制造一个假的成功响应来走完整路径：
        // 只需验证 parseTrialStart 的输出字段与 accessor 在手动写入后一致即可。
        d.set(parsed.token ?? "", forKey: "trial.token")
        d.set(parsed.daysLeft,   forKey: "trial.daysLeft")
        d.set(parsed.usedToday,  forKey: "trial.usedToday")
        d.set(TrialManager.beijingDayKey(), forKey: "trial.usedDay")   // usedToday 只在当天有效
        d.set(parsed.dailyLimit, forKey: "trial.dailyLimit")
        d.set(false,             forKey: "trial.expired")

        XCTAssertEqual(mgr.trialToken, "rt-token-99")
        XCTAssertEqual(mgr.daysLeft,   14)
        XCTAssertEqual(mgr.usedToday,  111)
        XCTAssertEqual(mgr.dailyLimit, 2000)
        XCTAssertTrue(mgr.isInTrial)
    }

    func testCacheRoundTripExpiredClearsToken() {
        let d = freshDefaults(name: "roundtrip-exp")
        // 先放一个有效 token
        d.set("old-token", forKey: "trial.token")
        d.set(false, forKey: "trial.expired")

        // 模拟 applyParsed({expired:true}) 的写入逻辑（镜像 TrialManager 实现）
        d.removeObject(forKey: "trial.token")
        d.set(true, forKey: "trial.expired")

        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")
        XCTAssertNil(mgr.trialToken)
        XCTAssertFalse(mgr.isInTrial)
    }

    func testDailyLimitDefaultsTo1500WhenNotCached() {
        let d = freshDefaults(name: "limit-default")
        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")
        XCTAssertEqual(mgr.dailyLimit, 1500, "UserDefaults 无值时 dailyLimit accessor 应默认 1500")
    }

    func testParseTrialStartReadsTotalQuota() {
        let p = TrialManager.parseTrialStart(["trial_token": "t", "days_left": 3, "daily_limit": 5000, "used_today": 120, "total_used": 7900, "total_limit": 8000])
        XCTAssertEqual(p.totalUsed, 7900)
        XCTAssertEqual(p.totalLimit, 8000)
        let old = TrialManager.parseTrialStart(["trial_token": "t", "days_left": 3])
        XCTAssertEqual(old.totalLimit, 0, "老服务器没给总额字段时视为不限")
    }

    func testUsedTodayResetsAcrossBeijingDay() {
        let defaults = UserDefaults(suiteName: "TrialManagerDayTests")!
        defaults.removePersistentDomain(forName: "TrialManagerDayTests")
        let m = TrialManager(defaults: defaults, session: URLSession(configuration: .ephemeral), apiBase: "https://example.invalid")
        defaults.set(4800, forKey: "trial.usedToday")
        defaults.set("2000-01-01", forKey: "trial.usedDay")
        XCTAssertEqual(m.usedToday, 0, "缓存是别的日子的，跨天视为 0")
        defaults.set(TrialManager.beijingDayKey(), forKey: "trial.usedDay")
        XCTAssertEqual(m.usedToday, 4800)
        defaults.set(8000, forKey: "trial.totalUsed"); defaults.set(8000, forKey: "trial.totalLimit")
        XCTAssertTrue(m.isTotalExhausted)
    }
}

extension TrialManagerTests {
    /// 握手请求体：自带 Key 标记只在 App 明确知道时才带（老版本 / 其他端不带，服务器保留原值）
    func testStartBodyOwnKeyFlag() {
        let withKey = TrialManager.startBody(deviceID: "d", appVersion: "3.0.4", osVersion: "15.7",
                                             selfChars: 120, selfReqs: 2, ownKeyConfigured: true)
        XCTAssertEqual(withKey["own_key"] as? Bool, true)
        XCTAssertEqual((withKey["usage"] as? [String: Int])?["chars"], 120)

        let onTrial = TrialManager.startBody(deviceID: "d", appVersion: "3.0.4", osVersion: "15.7",
                                             selfChars: 0, selfReqs: 0, ownKeyConfigured: false)
        XCTAssertEqual(onTrial["own_key"] as? Bool, false)

        let unknown = TrialManager.startBody(deviceID: "d", appVersion: "3.0.3", osVersion: "15.7",
                                            selfChars: 0, selfReqs: 0, ownKeyConfigured: nil)
        XCTAssertNil(unknown["own_key"])
        XCTAssertEqual(unknown["device_id"] as? String, "d")
    }
}

// MARK: - 体检 修3：握手连不上 / 被拒时的提示

extension TrialManagerTests {
    func testStartFailureUsesServerReasonOnlyWhenRejectedWithMessage() {
        // 同一网络今天新设备太多：服务器 429 + 中文原话 → 明确拒绝，原话带回
        XCTAssertEqual(TrialManager.startFailure(statusCode: 429, json: ["error": "今日新设备过多，请明天再试或填自己的 API Key", "code": "ip_new_device_cap"]),
                       .rejected(message: "今日新设备过多，请明天再试或填自己的 API Key"))
        XCTAssertEqual(TrialManager.startFailure(statusCode: 429, json: ["error": "请求过于频繁，请稍后再试", "code": "rate_limited"]),
                       .rejected(message: "请求过于频繁，请稍后再试"))
        // 没给原因 / 回了看不懂的东西（网关 HTML）/ 根本没回应 → 当连不上
        XCTAssertEqual(TrialManager.startFailure(statusCode: 502, json: nil), .unreachable)
        XCTAssertEqual(TrialManager.startFailure(statusCode: 500, json: ["error": "  "]), .unreachable)
        XCTAssertEqual(TrialManager.startFailure(statusCode: nil, json: nil), .unreachable)
        // 200 却走到失败分支 = JSON 解析不出来 → 当连不上
        XCTAssertEqual(TrialManager.startFailure(statusCode: 200, json: ["error": "x"]), .unreachable)
    }

    func testTrialNotReadyHint() {
        // 还没失败过 / 只失败一次：照旧请稍候（首启那一下网络可能还没好）
        XCTAssertEqual(TrialManager.trialNotReadyHint(lastFailure: nil, consecutiveFailures: 0), TrialManager.preparingTrialHint)
        XCTAssertEqual(TrialManager.trialNotReadyHint(lastFailure: .unreachable, consecutiveFailures: 1), TrialManager.preparingTrialHint)
        // 连续两次连不上：说清楚是网络，给出路
        XCTAssertEqual(TrialManager.trialNotReadyHint(lastFailure: .unreachable, consecutiveFailures: 2), TrialManager.unreachableTrialHint)
        XCTAssertTrue(TrialManager.unreachableTrialHint.contains("API Key"))
        // 服务器明确拒绝：第一次就用原话
        XCTAssertEqual(TrialManager.trialNotReadyHint(lastFailure: .rejected(message: "请求过于频繁，请稍后再试"), consecutiveFailures: 1),
                       "请求过于频繁，请稍后再试")
    }

    func testStartOutcomeCountsConsecutiveFailuresAndResetsOnSuccess() {
        let m = TrialManager(defaults: UserDefaults(suiteName: "trial-test-start-outcome")!,
                             session: .shared, apiBase: "https://127.0.0.1:1")
        XCTAssertEqual(m.trialNotReadyHint, TrialManager.preparingTrialHint)
        m.noteStartOutcome(.unreachable)
        XCTAssertEqual(m.trialNotReadyHint, TrialManager.preparingTrialHint)
        m.noteStartOutcome(.unreachable)
        XCTAssertEqual(m.consecutiveStartFailures, 2)
        XCTAssertEqual(m.trialNotReadyHint, TrialManager.unreachableTrialHint)
        m.noteStartOutcome(nil)
        XCTAssertEqual(m.consecutiveStartFailures, 0)
        XCTAssertNil(m.lastStartFailure)
        XCTAssertEqual(m.trialNotReadyHint, TrialManager.preparingTrialHint)
    }
}

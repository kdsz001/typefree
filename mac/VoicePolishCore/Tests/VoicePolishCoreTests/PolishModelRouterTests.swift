import XCTest
@testable import VoicePolishCore

final class PolishModelRouterTests: XCTestCase {

    private let suiteName = "PolishModelRouterTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testIsAuto() {
        XCTAssertTrue(PolishModelRouter.isAuto("auto"))
        XCTAssertTrue(PolishModelRouter.isAuto("auto-speed"))
        XCTAssertFalse(PolishModelRouter.isAuto("qwen3.8-max"))
        XCTAssertFalse(PolishModelRouter.isAuto(nil))
    }

    func testDefaultCandidatesAreQualityChain() {
        XCTAssertEqual(PolishModelRouter.candidates(defaults: defaults),
                       ["qwen3.7-plus", "qwen3.8-max", "qwen3.7-max", "qwen3.7-flash", "qwen3.6-flash"])
        XCTAssertEqual(PolishModelRouter.candidates(for: "auto", defaults: defaults),
                       ["qwen3.7-plus", "qwen3.8-max", "qwen3.7-max", "qwen3.7-flash", "qwen3.6-flash"])
    }

    func testSpeedCandidatesPutFlashFirst() {
        XCTAssertEqual(PolishModelRouter.candidates(for: "auto-speed", defaults: defaults),
                       ["qwen3.7-flash", "qwen3.6-flash", "qwen3.8-max", "qwen3.7-max"])
    }

    func testSpeedChainDegradesToMaxWhenFlashExhausted() {
        PolishModelRouter.markExhausted("qwen3.7-flash", defaults: defaults)
        PolishModelRouter.markExhausted("qwen3.6-flash", defaults: defaults)
        XCTAssertEqual(PolishModelRouter.candidates(for: "auto-speed", defaults: defaults),
                       ["qwen3.8-max", "qwen3.7-max"],
                       "flash 档额度用完 → 落到 max 档继续免费")
    }

    func testExhaustedModelIsSkipped() {
        PolishModelRouter.markExhausted("qwen3.8-max", defaults: defaults)
        XCTAssertEqual(PolishModelRouter.candidates(defaults: defaults),
                       ["qwen3.7-plus", "qwen3.7-max", "qwen3.7-flash", "qwen3.6-flash"])
    }

    func testAllExhaustedFallsBackToCheapest() {
        for m in PolishModelRouter.qualityChain {
            PolishModelRouter.markExhausted(m, defaults: defaults)
        }
        XCTAssertEqual(PolishModelRouter.candidates(defaults: defaults),
                       [PolishModelRouter.lastResort],
                       "全部额度用完 → 落到付费最便宜的模型")
    }

    func testCooldownExpires() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        PolishModelRouter.markExhausted("qwen3.8-max", now: t0, defaults: defaults)
        XCTAssertTrue(PolishModelRouter.isExhausted("qwen3.8-max",
                                                    now: t0.addingTimeInterval(19 * 3600),
                                                    defaults: defaults),
                      "冷却期内（19 小时）仍应视为额度用完")
        XCTAssertFalse(PolishModelRouter.isExhausted("qwen3.8-max",
                                                     now: t0.addingTimeInterval(21 * 3600),
                                                     defaults: defaults),
                       "冷却到期（21 小时）后应自动恢复重试")
        XCTAssertTrue(PolishModelRouter.candidates(now: t0.addingTimeInterval(21 * 3600),
                                                   defaults: defaults).contains("qwen3.8-max"),
                      "冷却到期后应回到候选队列")
    }

    func testClassify403QuotaVersusUnavailable() {
        let quota = AIPolisher.classify403(json: ["error": ["code": "AllocationQuota.FreeTierOnly", "message": "The free tier of the model has been exhausted."]], message: "x")
        guard case .quotaExhausted = quota else { return XCTFail("免费额度用完应归为额度类") }
        let denied = AIPolisher.classify403(json: ["error": ["code": "Model.AccessDenied", "message": "Model access denied."]], message: "x")
        guard case .modelUnavailable = denied else { return XCTFail("无权限不应说成额度用完") }
        XCTAssertEqual(PolishModelRouter.cooldown(for: .modelUnavailable("x")), PolishModelRouter.unavailableCooldown)
        XCTAssertNil(PolishModelRouter.cooldown(for: .apiError("x")))
    }
}

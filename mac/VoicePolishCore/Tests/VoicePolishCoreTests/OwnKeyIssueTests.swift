import XCTest
@testable import VoicePolishCore

/// 读钥匙串时报错（被锁 / 拒绝授权），区别于「没有」。
private final class UnreadableStore: SecretStoring {
    func get(_ a: String) -> String? { nil }
    func lookup(_ a: String) -> SecretLookup { .error("user interaction not allowed") }
    @discardableResult func set(_ a: String, _ v: String?) -> Bool { false }
}

/// 工单 #1030：自带 Key 用户在当前识别服务没 Key 时，原先一律提示「试用已结束」。
final class OwnKeyIssueTests: XCTestCase {

    private func transcriber(secrets: SecretStoring = InMemorySecretStore(),
                             keys: [String: String] = [:], version: String) -> CloudASRTranscriber {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vpcfg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = VoicePolishConfig(configDir: dir, secrets: secrets)
        for (k, v) in keys { config.save(value: v, forKey: k) }
        config.save(value: version, forKey: "bigasr_version")
        return CloudASRTranscriber(config: config)
    }

    func testConfiguredCurrentProviderHasNoIssue() {
        let t = transcriber(keys: ["bigasr_api_key": "v-key"], version: "turbo")
        XCTAssertTrue(t.isConfigured())
        XCTAssertNil(t.ownKeyIssue())
    }

    func testNoKeyAtAllFallsBackToTrialFlow() {
        XCTAssertNil(transcriber(version: "turbo").ownKeyIssue())
        XCTAssertNil(transcriber(version: "bailian").ownKeyIssue())
    }

    func testSwitchedToBailianWithOnlyVolcanoKey() {
        let t = transcriber(keys: ["bigasr_api_key": "v-key"], version: "bailian")
        XCTAssertFalse(t.isConfigured())
        XCTAssertEqual(t.ownKeyIssue(), .missingForCurrent(current: .bailian, configured: .volcano))
        XCTAssertEqual(CloudASRTranscriber.hint(for: t.ownKeyIssue()!),
                       "语音识别选的「百炼」还没填 Key · 在「设置 → 模型」填上，或改选已填 Key 的「火山引擎」")
    }

    func testVolcanoSelectedWithOnlyDashscopeKey() {
        let t = transcriber(keys: ["dashscope_api_key": "d-key"], version: "v2")
        XCTAssertEqual(t.ownKeyIssue(), .missingForCurrent(current: .volcano, configured: .bailian))
    }

    func testKeychainUnreadableIsReportedInsteadOfTrialExpired() {
        let t = transcriber(secrets: UnreadableStore(), version: "turbo")
        XCTAssertFalse(t.isConfigured())
        XCTAssertEqual(t.ownKeyIssue(), .keychainUnreadable)
    }
}

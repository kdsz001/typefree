import XCTest
@testable import VoicePolishCore

/// 优5（2026-11-19 体检）：试用 / 会员通道用的是服务器池子里的 Key，池子出问题时
/// 不能对用户说「API Key 无效，请检查是否复制完整」「请到服务商控制台检查」——那是写给自带 Key 用户的。
final class HostedKeyErrorWordingTests: XCTestCase {

    private let unavailable = "服务暂时不可用，请稍后再试"

    // MARK: - 润色 / 问 AI（千问，服务器把上游错误原样转回）

    func testHostedUpstreamInvalidKeyIsServiceUnavailable() {
        let upstream: [String: Any] = ["error": ["code": "invalid_api_key", "message": "Incorrect API key provided."]]
        XCTAssertEqual(AIPolisher.hostedErrorMessage(status: 401, json: upstream), unavailable)
        // 状态码不是 401/403 也按内容认：Key 无效
        XCTAssertEqual(AIPolisher.hostedErrorMessage(status: 400, json: upstream), unavailable)
    }

    func testHostedUpstreamArrearageIsServiceUnavailable() {
        // 千问欠费回的是 400 Arrearage（见 trial-server/dashscope.js）
        let upstream: [String: Any] = ["error": ["code": "Arrearage", "message": "Access denied, please make sure your account is in good standing."]]
        XCTAssertEqual(AIPolisher.hostedErrorMessage(status: 400, json: upstream), unavailable)
    }

    func testHostedUpstreamForbiddenIsServiceUnavailable() {
        let upstream: [String: Any] = ["error": ["code": "Model.AccessDenied", "message": "The model does not exist or you do not have access to it."]]
        XCTAssertEqual(AIPolisher.hostedErrorMessage(status: 403, json: upstream), unavailable)
        XCTAssertEqual(AIPolisher.hostedErrorMessage(status: 403, json: nil), unavailable)
    }

    /// 服务器自己的拦截（额度用完、限流、令牌无效）带中文原话，照用不改
    func testHostedServerOwnMessageIsKept() {
        XCTAssertEqual(AIPolisher.hostedErrorMessage(status: 429, json: ["error": "试用润色额度已用完", "code": "trial_polish_quota"]),
                       "试用润色额度已用完")
        XCTAssertEqual(AIPolisher.hostedErrorMessage(status: 401, json: ["error": "试用令牌无效", "code": "bad_trial_token"]),
                       "试用令牌无效")
        XCTAssertEqual(AIPolisher.hostedErrorMessage(status: 502, json: ["error": "润色服务暂时不可用，请稍后再试", "code": "upstream_unavailable"]),
                       "润色服务暂时不可用，请稍后再试")
    }

    /// 跟 Key 无关的上游错误（内容审核、限流）照旧
    func testHostedNonKeyUpstreamErrorUnchanged() {
        let inspection: [String: Any] = ["error": ["code": "data_inspection_failed", "message": "Input data may contain inappropriate content."]]
        XCTAssertEqual(AIPolisher.hostedErrorMessage(status: 400, json: inspection), "Input data may contain inappropriate content.")
        let throttled: [String: Any] = ["error": ["code": "Throttling", "message": "Requests rate limit exceeded"]]
        XCTAssertEqual(AIPolisher.hostedErrorMessage(status: 429, json: throttled), "请求太频繁或额度超限，稍后再试（Throttling）")
    }

    /// 自带 Key 的用户：文案保持原样（他确实该去查自己的 Key）
    func testOwnKeyWordingUnchanged() {
        XCTAssertEqual(AIPolisher.extractAPIErrorMessage(from: ["error": ["code": "invalid_api_key", "message": "Incorrect API key provided."]]),
                       "API Key 无效，请检查是否复制完整（invalid_api_key）")
        XCTAssertEqual(AIPolisher.extractAPIErrorMessage(from: ["error": ["code": "Arrearage", "message": "Access denied, please make sure your account is in good standing."]]),
                       "账号欠费或免费额度已用完，请到服务商控制台检查（Arrearage）")
    }

    // MARK: - 识别（火山，服务器 200 + X-Api-Status-Code 原样转回）

    func testHostedVolcanoKeyErrorsAreServiceUnavailable() {
        let t = CloudASRTranscriber()
        for code in [45000010, 45000030] {
            let err = t.classifyServerError(status: code, data: nil, hosted: true)
            XCTAssertEqual(err.errorDescription, unavailable, "状态码 \(code)")
        }
    }

    func testOwnKeyVolcanoWordingUnchanged() {
        let t = CloudASRTranscriber()
        XCTAssertEqual(t.classifyServerError(status: 45000010, data: nil).errorDescription, "火山 API Key 无效，请检查是否复制完整（45000010）")
        XCTAssertEqual(t.classifyServerError(status: 45000030, data: nil).errorDescription, "火山账号未开通此识别版本，请到控制台开通并领免费额度（45000030）")
    }

    /// 托管通道里其它状态码的处理不变：无语音仍当「没内容」，繁忙仍可原地重试
    func testHostedOtherVolcanoCodesUnchanged() {
        let t = CloudASRTranscriber()
        guard case .noSpeech = t.classifyServerError(status: 20000003, data: nil, hosted: true) else { return XCTFail("应为 noSpeech") }
        XCTAssertTrue(t.classifyServerError(status: 55000031, data: nil, hosted: true).isRetriableInPlace)
    }
}

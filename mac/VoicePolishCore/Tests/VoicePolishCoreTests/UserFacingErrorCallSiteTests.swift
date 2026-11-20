import XCTest
@testable import VoicePolishCore

/// 体检 修4 补齐：发反馈、激活授权遇到网络错误时，给界面的原因是中文短句，不带系统英文原话、网址、IP。
final class UserFacingErrorCallSiteTests: XCTestCase {

    private func timingOutSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingProtocol.self]
        return URLSession(configuration: config)
    }

    func testFeedbackNetworkErrorIsChinese() {
        var got: FeedbackService.FeedbackError?
        let done = expectation(description: "completion")
        FeedbackService.send(message: "测试反馈", appVersion: "3.0.15", modelEnvironment: nil,
                             apiBase: "https://feedback.test", session: timingOutSession()) { result in
            if case .failure(let e) = result { got = e }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(got, .network("网络超时"))
    }

    func testActivationNetworkErrorIsChinese() {
        let defaults = UserDefaults(suiteName: "ufe-callsite-\(UUID().uuidString)")!
        let manager = LicenseManager(defaults: defaults, session: timingOutSession(), apiBase: "https://license.test")
        var got: LicenseManager.ActivationError?
        let done = expectation(description: "completion")
        manager.activate(key: "TEST-CODE", instanceName: "") { result in
            if case .failure(let e) = result { got = e }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(got, .network("网络超时"))
    }
}

/// 所有请求都以「请求超时」失败（系统原话是英文、带请求网址）
private final class FailingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: request.url?.absoluteString ?? ""]))
    }
    override func stopLoading() {}
}

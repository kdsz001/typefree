import XCTest
@testable import VoicePolishCore

/// 修4（2026-11-19 体检）：网络错误给用户看的一律是中文短句，不带网址、IP、英文调试串。
final class UserFacingErrorTests: XCTestCase {

    private func urlError(_ code: Int, description: String? = nil) -> NSError {
        var info: [String: Any] = [
            NSURLErrorFailingURLStringErrorKey: "https://203.0.113.7:8443/trial/polish",
            NSURLErrorFailingURLErrorKey: URL(string: "https://203.0.113.7:8443/trial/polish")!,
        ]
        if let description { info[NSLocalizedDescriptionKey] = description }
        return NSError(domain: NSURLErrorDomain, code: code, userInfo: info)
    }

    private func assertClean(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains("://"), "不能带网址：\(text)", file: file, line: line)
        XCTAssertFalse(text.contains("203.0.113"), "不能带服务器 IP：\(text)", file: file, line: line)
        XCTAssertFalse(text.contains("Error Domain"), "不能带系统调试串：\(text)", file: file, line: line)
        XCTAssertFalse(text.contains("NSURLError"), "不能带系统调试串：\(text)", file: file, line: line)
    }

    // MARK: - 网络错误码 → 中文短句

    func testNetworkErrorCodesMapToChinese() {
        XCTAssertEqual(UserFacingError.networkMessage(for: URLError(.timedOut)), "网络超时")
        XCTAssertEqual(UserFacingError.networkMessage(for: URLError(.notConnectedToInternet)), "没有连上网络")
        XCTAssertEqual(UserFacingError.networkMessage(for: URLError(.networkConnectionLost)), "网络连接中断")
        XCTAssertEqual(UserFacingError.networkMessage(for: URLError(.cannotFindHost)), "连不上服务器")
        XCTAssertEqual(UserFacingError.networkMessage(for: URLError(.cannotConnectToHost)), "连不上服务器")
        XCTAssertEqual(UserFacingError.networkMessage(for: URLError(.badServerResponse)), "服务器响应异常")
        XCTAssertTrue(UserFacingError.networkMessage(for: URLError(.serverCertificateUntrusted))?.hasPrefix("网络安全校验没通过") == true)
        XCTAssertTrue(UserFacingError.networkMessage(for: URLError(.secureConnectionFailed))?.hasPrefix("网络安全校验没通过") == true)
        // 试用 / 会员通道证书指纹对不上时系统报「已取消」
        XCTAssertTrue(UserFacingError.networkMessage(for: URLError(.cancelled))?.hasPrefix("网络连接被中断") == true)
        // 认不出的网络错误码：通用说法
        XCTAssertEqual(UserFacingError.networkMessage(for: URLError(.fileDoesNotExist)), "网络出错")
    }

    func testNonNetworkErrorIsNotTreatedAsNetwork() {
        struct Other: Error {}
        XCTAssertNil(UserFacingError.networkMessage(for: Other()))
        XCTAssertNil(UserFacingError.networkMessage(for: NSError(domain: NSCocoaErrorDomain, code: 3840)))
    }

    // MARK: - 任意错误 → 给用户看的话

    /// 体检原样：证书错误的系统描述里带服务器 IP，以前 "\(err)" 整段显示出来
    func testCertificateErrorWithServerIPShowsOnlyChinese() {
        let err = urlError(NSURLErrorServerCertificateUntrusted,
                           description: "The certificate for this server is invalid. You might be connecting to a server that is pretending to be “203.0.113.7” which could put your confidential information at risk.")
        let text = UserFacingError.message(for: err, fallback: "兜底")
        XCTAssertTrue(text.hasPrefix("网络安全校验没通过"))
        assertClean(text)
    }

    func testTimeoutShowsShortChinese() {
        let text = UserFacingError.message(for: urlError(NSURLErrorTimedOut), fallback: "兜底")
        XCTAssertEqual(text, "网络超时")
    }

    func testUnknownErrorUsesFallback() {
        struct Weird: Error {}
        XCTAssertEqual(UserFacingError.message(for: Weird(), fallback: "服务出错了"), "服务出错了")
        // 系统自带的 LocalizedError（英文说明）也不显示
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        XCTAssertEqual(UserFacingError.message(for: decoding, fallback: "服务出错了"), "服务出错了")
    }

    func testOwnErrorsKeepTheirChineseText() {
        XCTAssertEqual(UserFacingError.message(for: AIPolisher.PolishError.apiError("API Key 无效，请检查是否复制完整（invalid_api_key）"), fallback: "x"),
                       "API Key 无效，请检查是否复制完整（invalid_api_key）")
        XCTAssertEqual(UserFacingError.message(for: CloudASRTranscriber.TranscriptionError.timeout, fallback: "x"), "识别超时")
        XCTAssertEqual(UserFacingError.message(for: CloudASRTranscriber.TranscriptionError.serverFailed(message: "试用已结束 · 开通会员，或在「设置 → 模型」填自己的 Key"), fallback: "x"),
                       "试用已结束 · 开通会员，或在「设置 → 模型」填自己的 Key")
    }

    /// 识别那条路径：网络错误包在 TranscriptionError.network 里，以前显示「网络错误：<系统原话>」
    func testTranscriptionNetworkErrorDescriptionIsChinese() {
        let err = CloudASRTranscriber.TranscriptionError.network(underlying: urlError(NSURLErrorTimedOut, description: "The request timed out."))
        XCTAssertEqual(err.errorDescription, "网络超时")
        XCTAssertEqual(UserFacingError.message(for: err, fallback: "x"), "网络超时")
        let cert = CloudASRTranscriber.TranscriptionError.network(underlying: urlError(NSURLErrorServerCertificateUntrusted, description: "pretending to be “203.0.113.7”"))
        assertClean(cert.errorDescription ?? "")
    }

    // MARK: - 包一层：App 里 `(err as? LocalizedError)?.errorDescription ?? "\(err)"` 也只拿到中文

    func testWrappedNetworkErrorIsLocalizedChinese() {
        let wrapped = UserFacingError.wrappingNetworkError(urlError(NSURLErrorNotConnectedToInternet, description: "The Internet connection appears to be offline."))
        XCTAssertEqual((wrapped as? LocalizedError)?.errorDescription, "没有连上网络")
        XCTAssertEqual(wrapped.localizedDescription, "没有连上网络")
        // 包了一层也认得出是网络错误；日志里 "\(err)" 仍保留原始错误，方便排查
        XCTAssertEqual(UserFacingError.message(for: wrapped, fallback: "x"), "没有连上网络")
        XCTAssertTrue("\(wrapped)".contains("NSURLErrorDomain"))
    }

    func testWrappingLeavesOtherErrorsAlone() {
        let polish = AIPolisher.PolishError.parseError
        XCTAssertTrue(UserFacingError.wrappingNetworkError(polish) is AIPolisher.PolishError)
        struct Other: Error {}
        XCTAssertTrue(UserFacingError.wrappingNetworkError(Other()) is Other)
    }

    // MARK: - 最后一道：服务器原话里夹着的网址 / IP

    func testServerMessageWithLinkKeepsTextDropsLink() {
        let msg = "Input data may contain inappropriate content. For details, see: https://help.aliyun.com/zh/model-studio/error-code#inappropriate-content"
        XCTAssertEqual(AIPolisher.PolishError.apiError(msg).errorDescription, "Input data may contain inappropriate content")
    }

    func testMessageWithoutLinkOrIPIsUntouched() {
        let msg = "百炼识别最长支持 5 分钟，这段约 12 分钟太长了。请在「模型」里改用火山 2.0，或把录音分短一些。"
        XCTAssertEqual(UserFacingError.sanitized(msg, fallback: "x"), msg)
        XCTAssertEqual(UserFacingError.sanitized("火山 API Key 无效，请检查是否复制完整（45000010）", fallback: "x"),
                       "火山 API Key 无效，请检查是否复制完整（45000010）")
    }

    func testIPInsideChineseIsRemoved() {
        let text = UserFacingError.sanitized("连不上服务器203.0.113.7:8443，请稍后再试", fallback: "x")
        assertClean(text)
        XCTAssertTrue(text.contains("连不上服务器"))
    }

    func testOnlyLinkOrDebugDumpFallsBack() {
        XCTAssertEqual(UserFacingError.sanitized("https://203.0.113.7:8443/trial/asr", fallback: "兜底"), "兜底")
        XCTAssertEqual(UserFacingError.sanitized("Error Domain=NSURLErrorDomain Code=-1001 \"The request timed out.\"", fallback: "兜底"), "兜底")
    }
}

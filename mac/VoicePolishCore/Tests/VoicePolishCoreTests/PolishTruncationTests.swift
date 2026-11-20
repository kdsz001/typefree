import XCTest
@testable import VoicePolishCore

/// 体检优10：豆包 / 智谱润色写死 max_tokens 2000，输出被截断时以前把半截稿当完整结果悄悄打出去。
/// 现在认 finish_reason=length，按「润色失败 → 输出原文并提示」走。
final class PolishTruncationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChatStubProtocol.response = nil
        URLProtocol.registerClass(ChatStubProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(ChatStubProtocol.self)
        ChatStubProtocol.response = nil
        super.tearDown()
    }

    private func call() -> Result<(String, Int, Int), Error>? {
        var result: Result<(String, Int, Int), Error>?
        let done = expectation(description: "call")
        AIPolisher().callChatCompletionsWithTokens(url: URL(string: "https://chat-stub.invalid/v1/chat/completions")!,
                                                   apiKey: "test", body: ["model": "m"]) { r in
            result = r
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }

    func testTruncatedOutputIsTreatedAsFailure() {
        ChatStubProtocol.response = ["choices": [["message": ["content": "第一段整理好了，第二段写到一半"], "finish_reason": "length"]]]
        guard case .failure(let error)? = call() else { return XCTFail("被截断不能当成功") }
        guard case AIPolisher.PolishError.outputTruncated = error else { return XCTFail("应为 outputTruncated：\(error)") }
        // 流水线显示成「已输出未润色文字（润色失败：这段太长，润色没能写完）」
        XCTAssertEqual(UserFacingError.message(for: error, fallback: "x"), "这段太长，润色没能写完")
    }

    func testCompleteOutputUnchanged() {
        ChatStubProtocol.response = ["choices": [["message": ["content": " 整理好的全文 "], "finish_reason": "stop"]],
                                     "usage": ["prompt_tokens": 12, "completion_tokens": 5]]
        guard case .success(let (text, inTokens, outTokens))? = call() else { return XCTFail("应成功") }
        XCTAssertEqual(text, "整理好的全文")
        XCTAssertEqual(inTokens, 12)
        XCTAssertEqual(outTokens, 5)
    }

    /// 有的服务商不回 finish_reason：照旧当完整结果
    func testMissingFinishReasonUnchanged() {
        ChatStubProtocol.response = ["choices": [["message": ["content": "全文"]]]]
        guard case .success(let (text, _, _))? = call() else { return XCTFail("应成功") }
        XCTAssertEqual(text, "全文")
    }

    func testFinishReasonDetection() {
        XCTAssertTrue(AIPolisher.isTruncatedByLength(["finish_reason": "length"]))
        XCTAssertFalse(AIPolisher.isTruncatedByLength(["finish_reason": "stop"]))
        XCTAssertFalse(AIPolisher.isTruncatedByLength(["finish_reason": NSNull()]))
        XCTAssertFalse(AIPolisher.isTruncatedByLength([:]))
    }

    /// 截断不是额度问题：自动路由不该因此给模型记冷却、换模型
    func testTruncationDoesNotTriggerModelCooldown() {
        XCTAssertNil(PolishModelRouter.cooldown(for: .outputTruncated))
    }
}

/// 只接管 chat-stub.invalid 的假接口
private final class ChatStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _response: [String: Any]?
    static var response: [String: Any]? {
        get { lock.lock(); defer { lock.unlock() }; return _response }
        set { lock.lock(); _response = newValue; lock.unlock() }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "chat-stub.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: Self.response ?? [:])) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

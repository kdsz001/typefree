import XCTest
@testable import VoicePolishCore

final class CloudASRTranscriberTests: XCTestCase {

    // MARK: - recognitionBudget：识别等待预算随音频时长放宽（修长录音超时白录的回归）

    /// 短录音基础预算 20s（工单 #1024：原先 60s，网络一卡每步干等一分钟）；按时长 ×0.5 放宽。
    func testBudgetShortAudioBase20() {
        XCTAssertEqual(CloudASRTranscriber.recognitionBudget(audioSeconds: 0), 20, accuracy: 0.001)
        XCTAssertEqual(CloudASRTranscriber.recognitionBudget(audioSeconds: 5), 22.5, accuracy: 0.001)
        // 60s 录音 → 60*0.5+20 = 50
        XCTAssertEqual(CloudASRTranscriber.recognitionBudget(audioSeconds: 60), 50, accuracy: 0.001)
    }

    /// 长录音放宽，但封顶 600s（10 分钟）。30 分钟曾因死守 60s 超时 → 现在给足时间。
    func testBudgetLongAudioCappedAt600() {
        // 20 分钟（1200s）→ 1200*0.5+20 = 620 → 封顶 600
        XCTAssertEqual(CloudASRTranscriber.recognitionBudget(audioSeconds: 1200), 600, accuracy: 0.001)
        // 30 分钟（1800s）→ 同样封顶 600
        XCTAssertEqual(CloudASRTranscriber.recognitionBudget(audioSeconds: 1800), 600, accuracy: 0.001)
    }

    /// 关键回归点：30 分钟录音的预算必须明显大于旧的写死 60s（否则又会提前超时白录）。
    func testBudgetForThirtyMinutesIsWellAboveOldSixtySeconds() {
        XCTAssertGreaterThan(CloudASRTranscriber.recognitionBudget(audioSeconds: 1800), 60)
    }

    // MARK: - 分段识别的对象生命周期（修历史「重试」永久卡死的回归）

    /// 分段是由协调器在它自己的串行队列上**异步**启动的，此时调用方的方法通常已经返回。
    /// 若 transcribeAuto 内部对 self 用弱引用，转写器会在分段启动前被释放 →
    /// 分段闭包直接 return → chunkCompletion 永不回调 → 整次识别永久挂起。
    /// 历史记录「重试」正是这样卡死的（转圈一直转、永远不出结果）。
    /// 本用例断言：调用方释放本地引用后，转写器仍被在途识别持有。
    func testTranscribeAutoKeepsTranscriberAliveAfterCallerReleasesIt() {
        var seed: UInt64 = 42
        // 造一段会被切成多段的音频：说话 / 停顿 交替，总长 > 10s
        var samples: [Float] = []
        for _ in 0..<3 {
            samples += chunkableSpeech(seconds: 5, seed: &seed)
            samples += chunkableSilence(seconds: 1.2, seed: &seed)
        }
        XCTAssertGreaterThan(AudioChunker.plan(samples: samples, sampleRate: 16000).count, 1,
                             "前置条件：这段音频必须会被分段，否则测不到目标路径")

        weak var weakTranscriber: CloudASRTranscriber?
        autoreleasepool {
            let transcriber = CloudASRTranscriber()
            weakTranscriber = transcriber
            transcriber.transcribeAuto(samples: samples, sampleRate: 16000, version: .turbo) { _ in }
            // 调用方在这里放手（真实场景：@objc 方法返回、局部变量被释放）
        }
        XCTAssertNotNil(weakTranscriber,
                        "识别在途时转写器被释放了 → 分段永远启动不了，整次识别会永久挂起")
    }

    private func chunkableSpeech(seconds: Double, seed: inout UInt64) -> [Float] {
        let count = Int(seconds * 16000)
        return (0..<count).map { i in
            0.2 * sin(2 * .pi * 440 * Float(i) / 16000) + 0.01 * pseudoRandomSample(&seed)
        }
    }

    private func chunkableSilence(seconds: Double, seed: inout UInt64) -> [Float] {
        let count = Int(seconds * 16000)
        return (0..<count).map { _ in 0.01 * pseudoRandomSample(&seed) }
    }

    private func pseudoRandomSample(_ seed: inout UInt64) -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
    }

    func testTransientNetworkErrorsAreRetriable() {
        typealias E = CloudASRTranscriber.TranscriptionError
        XCTAssertTrue(E.network(underlying: URLError(.networkConnectionLost)).isRetriableInPlace)
        XCTAssertTrue(E.network(underlying: URLError(.timedOut)).isRetriableInPlace)
        XCTAssertFalse(E.network(underlying: URLError(.notConnectedToInternet)).isRetriableInPlace)
        XCTAssertFalse(E.parseError.isRetriableInPlace)
    }
}

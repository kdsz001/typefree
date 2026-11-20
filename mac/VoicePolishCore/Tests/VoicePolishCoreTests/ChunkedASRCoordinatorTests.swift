import XCTest
@testable import VoicePolishCore

final class ChunkedASRCoordinatorTests: XCTestCase {

    /// n 段等长假音频 + 对应区间（内容无所谓，调度只看区间数）
    private func fixture(chunks n: Int) -> (samples: [Float], ranges: [Range<Int>]) {
        let samples = [Float](repeating: 0, count: n)
        let ranges = (0..<n).map { $0..<($0 + 1) }
        return (samples, ranges)
    }

    /// 后面的段先返回，结果仍按原始顺序拼接
    func testJoinsInOriginalOrderDespiteOutOfOrderCompletion() {
        let (samples, ranges) = fixture(chunks: 6)
        let exp = expectation(description: "done")
        ChunkedASRCoordinator.run(samples: samples, ranges: ranges, maxConcurrent: 6, transcribeChunk: { index, _, completion in
            // 越靠前的段完成得越晚
            let delay = Double(6 - index) * 0.03
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                completion(.success("段\(index)。"))
            }
        }, completion: { result in
            if case .success(let text) = result {
                XCTAssertEqual(text, "段0。段1。段2。段3。段4。段5。")
            } else {
                XCTFail("should succeed")
            }
            exp.fulfill()
        })
        wait(for: [exp], timeout: 5)
    }

    /// 同时在途的请求数不超过并发上限，完成一个补发一个，最终全部完成
    func testConcurrencyCapRespected() {
        let (samples, ranges) = fixture(chunks: 10)
        let lock = NSLock()
        var inFlight = 0
        var maxObserved = 0
        let exp = expectation(description: "done")
        ChunkedASRCoordinator.run(samples: samples, ranges: ranges, maxConcurrent: 3, transcribeChunk: { index, _, completion in
            lock.lock()
            inFlight += 1
            maxObserved = max(maxObserved, inFlight)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                lock.lock()
                inFlight -= 1
                lock.unlock()
                completion(.success("段\(index)，"))
            }
        }, completion: { result in
            if case .success(let text) = result {
                XCTAssertEqual(text, "段0，段1，段2，段3，段4，段5，段6，段7，段8，段9，")
            } else {
                XCTFail("should succeed")
            }
            exp.fulfill()
        })
        wait(for: [exp], timeout: 5)
        XCTAssertLessThanOrEqual(maxObserved, 3)
        XCTAssertGreaterThan(maxObserved, 1, "应该真的并行了")
    }

    /// 近静音段(能量≈0)被判无语音 → 记空文本继续，不触发并段恢复
    func testSilentNoSpeechChunkBecomesEmptyText() {
        let (samples, ranges) = fixture(chunks: 3)
        let exp = expectation(description: "done")
        ChunkedASRCoordinator.run(samples: samples, ranges: ranges, maxConcurrent: 3, transcribeChunk: { index, _, completion in
            DispatchQueue.global().async {
                if index == 1 {
                    completion(.failure(CloudASRTranscriber.TranscriptionError.noSpeech))
                } else {
                    completion(.success(index == 0 ? "甲" : "乙"))
                }
            }
        }, completion: { result in
            if case .success(let text) = result {
                XCTAssertEqual(text, "甲乙")
            } else {
                XCTFail("should succeed")
            }
            exp.fulfill()
        })
        wait(for: [exp], timeout: 5)
    }

    /// 有能量的段被误判无语音 → 并回上一段重识别恢复（不丢内容）
    func testNoSpeechWithEnergyRecoversByMerge() {
        // 三段各 8000 样本：段0/2 小声(0.05)，段1 大声(0.3) 但被判无语音
        let amp: [Float] = [0.05, 0.30, 0.05]
        var samples: [Float] = []
        var ranges: [Range<Int>] = []
        for a in amp {
            let start = samples.count
            for i in 0..<8000 { samples.append(a * ((i % 2 == 0) ? 1 : -1)) }
            ranges.append(start..<samples.count)
        }
        let mergedStart = ranges[0].lowerBound
        let mergedEnd = ranges[1].upperBound
        let exp = expectation(description: "done")
        ChunkedASRCoordinator.run(samples: samples, ranges: ranges, maxConcurrent: 3, transcribeChunk: { index, chunk, completion in
            DispatchQueue.global().async {
                // 合并段(段0+段1的样本数)→ 返回完整文本
                if index == 0 && chunk.count == mergedEnd - mergedStart {
                    completion(.success("甲乙"))
                } else if index == 1 {
                    completion(.failure(CloudASRTranscriber.TranscriptionError.noSpeech))
                } else {
                    completion(.success(index == 0 ? "甲" : "丙"))
                }
            }
        }, completion: { result in
            if case .success(let text) = result {
                // 段1 的内容经并段恢复进段0 → "甲乙" + 段2 "丙"
                XCTAssertEqual(text, "甲乙丙")
            } else {
                XCTFail("should succeed")
            }
            exp.fulfill()
        })
        wait(for: [exp], timeout: 5)
    }

    /// 优3：并段恢复途中被取消 → 整体失败，后面待恢复的段不再发
    func testCancelledRecoveryStopsFurtherRecovery() {
        // 五段：段1、段3 大声但被判无语音 → 两个待恢复目标
        let amp: [Float] = [0.05, 0.30, 0.05, 0.30, 0.05]
        var samples: [Float] = []
        var ranges: [Range<Int>] = []
        for a in amp {
            let start = samples.count
            for i in 0..<8000 { samples.append(a * ((i % 2 == 0) ? 1 : -1)) }
            ranges.append(start..<samples.count)
        }
        let lock = NSLock()
        var recoveryCalls = 0
        var result: Result<String, Error>?
        let exp = expectation(description: "done")
        ChunkedASRCoordinator.run(samples: samples, ranges: ranges, maxConcurrent: 5, transcribeChunk: { index, chunk, completion in
            DispatchQueue.global().async {
                if chunk.count > 8000 {   // 并段恢复请求
                    lock.lock(); recoveryCalls += 1; lock.unlock()
                    completion(.failure(CloudASRTranscriber.cancelledError))
                } else if index == 1 || index == 3 {
                    completion(.failure(CloudASRTranscriber.TranscriptionError.noSpeech))
                } else {
                    completion(.success("段\(index)"))
                }
            }
        }, completion: { r in
            result = r
            exp.fulfill()
        })
        wait(for: [exp], timeout: 5)
        guard case .failure(let error)? = result else { return XCTFail("取消后应失败") }
        XCTAssertTrue(CloudASRTranscriber.isCancellation(error))
        Thread.sleep(forTimeInterval: 0.1)
        lock.lock(); XCTAssertEqual(recoveryCalls, 1, "第一次恢复被取消后，第二个目标不该再发"); lock.unlock()
    }

    /// 临时性失败（服务器繁忙）原地重试一次后成功
    func testTransientFailureRetriedOnceThenSucceeds() {
        let (samples, ranges) = fixture(chunks: 3)
        let lock = NSLock()
        var attempts: [Int: Int] = [:]
        let exp = expectation(description: "done")
        ChunkedASRCoordinator.run(samples: samples, ranges: ranges, maxConcurrent: 3, transcribeChunk: { index, _, completion in
            lock.lock()
            attempts[index, default: 0] += 1
            let attempt = attempts[index]!
            lock.unlock()
            DispatchQueue.global().async {
                if index == 1 && attempt == 1 {
                    completion(.failure(CloudASRTranscriber.TranscriptionError.serverBusy(message: "繁忙")))
                } else {
                    completion(.success("段\(index)"))
                }
            }
        }, completion: { result in
            if case .success(let text) = result {
                XCTAssertEqual(text, "段0段1段2")
            } else {
                XCTFail("should succeed after retry")
            }
            exp.fulfill()
        })
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(attempts[1], 2)
    }

    /// 临时性失败重试后仍失败 → 整体失败，且只回调一次
    func testTransientFailureTwiceFailsWholeJob() {
        let (samples, ranges) = fixture(chunks: 3)
        let lock = NSLock()
        var completionCount = 0
        let exp = expectation(description: "done")
        ChunkedASRCoordinator.run(samples: samples, ranges: ranges, maxConcurrent: 3, transcribeChunk: { index, _, completion in
            DispatchQueue.global().async {
                if index == 1 {
                    completion(.failure(CloudASRTranscriber.TranscriptionError.serverBusy(message: "一直繁忙")))
                } else {
                    completion(.success("\(index)"))
                }
            }
        }, completion: { result in
            lock.lock()
            completionCount += 1
            lock.unlock()
            guard case .failure = result else {
                XCTFail("should fail")
                exp.fulfill()
                return
            }
            exp.fulfill()
        })
        wait(for: [exp], timeout: 5)
        // 等在途的段全部结束，确认不会二次回调
        Thread.sleep(forTimeInterval: 0.2)
        lock.lock()
        XCTAssertEqual(completionCount, 1)
        lock.unlock()
    }

    /// 业务性失败（如额度耗尽）不重试，直接整体失败
    func testPermanentFailureFailsWholeJob() {
        let (samples, ranges) = fixture(chunks: 4)
        let lock = NSLock()
        var attempts: [Int: Int] = [:]
        let exp = expectation(description: "done")
        ChunkedASRCoordinator.run(samples: samples, ranges: ranges, maxConcurrent: 4, transcribeChunk: { index, _, completion in
            lock.lock()
            attempts[index, default: 0] += 1
            lock.unlock()
            DispatchQueue.global().async {
                if index == 2 {
                    completion(.failure(CloudASRTranscriber.TranscriptionError.serverFailed(message: "额度耗尽")))
                } else {
                    completion(.success("\(index)"))
                }
            }
        }, completion: { result in
            guard case .failure(let error) = result,
                  case CloudASRTranscriber.TranscriptionError.serverFailed = error else {
                XCTFail("should fail with serverFailed")
                exp.fulfill()
                return
            }
            exp.fulfill()
        })
        wait(for: [exp], timeout: 5)
        Thread.sleep(forTimeInterval: 0.1)
        lock.lock()
        XCTAssertEqual(attempts[2], 1, "业务性失败不应重试")
        lock.unlock()
    }

    /// 英文分段拼接要补空格，不能粘成 "today.I think"
    func testEnglishChunksJoinedWithSpace() {
        let (samples, ranges) = fixture(chunks: 3)
        let texts = ["Thank you for coming today. ", "I think it works", "much better."]
        let exp = expectation(description: "done")
        ChunkedASRCoordinator.run(samples: samples, ranges: ranges, maxConcurrent: 3, transcribeChunk: { index, _, completion in
            DispatchQueue.global().async { completion(.success(texts[index])) }
        }, completion: { result in
            if case .success(let text) = result {
                XCTAssertEqual(text, "Thank you for coming today. I think it works much better.")
            } else {
                XCTFail("should succeed")
            }
            exp.fulfill()
        })
        wait(for: [exp], timeout: 5)
    }
}

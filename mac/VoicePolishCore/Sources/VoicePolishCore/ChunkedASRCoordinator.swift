import Foundation

/// 把切好的多段音频按并发上限并行识别，按原始顺序拼接结果。
///
/// 失败处理：
/// - 单段临时性失败（服务器繁忙/超时）原地重试一次；
/// - 单段被判「无有效语音」：若该段能量明显高于底噪（说明其实有说话、被识别接口误判），
///   并回上一存活段重识别（无语音恢复）；否则当作真静音记空文本；
/// - 任何一段最终失败 → 整体失败、只回调一次，沿用上层现有的报错/长录音存历史兜底。
///
/// 无语音恢复的由来：火山极速版偶尔对「短句 + 尾随静音」的段返回 20000003（无语音），
/// 实测把该段并回相邻段重识别即可完整恢复。合并永远安全：最坏多调一次，绝不丢内容。
final class ChunkedASRCoordinator {

    /// 识别单段音频：(段序号, 该段样本, 完成回调)。段序号仅用于日志/测试。
    typealias ChunkTranscriber = (_ index: Int, _ samples: [Float], _ completion: @escaping (Result<String, Error>) -> Void) -> Void

    /// 空段能量高于「底噪 × 此倍数」即判定为疑似误判、触发并段恢复
    static let recoveryEnergyFactor: Float = 1.5

    static func run(samples: [Float],
                    ranges: [Range<Int>],
                    maxConcurrent: Int,
                    transcribeChunk: @escaping ChunkTranscriber,
                    completion: @escaping (Result<String, Error>) -> Void) {
        let state = State(chunkCount: ranges.count,
                          maxConcurrent: max(1, maxConcurrent),
                          samples: samples,
                          ranges: ranges,
                          transcribeChunk: transcribeChunk,
                          completion: completion)
        state.queue.async { state.fillSlots() }
    }

    /// 计算并段恢复用的底噪水平（帧能量的 P10）。空/极短音频返回 0。
    static func noiseFloor(samples: [Float]) -> Float {
        let energies = AudioChunker.frameEnergies(samples: samples)
        guard !energies.isEmpty else { return 0 }
        return AudioChunker.percentile(energies.sorted(), 10)
    }

    static func segmentRMS(samples: [Float], range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var sum: Float = 0
        for i in range { sum += samples[i] * samples[i] }
        return (sum / Float(range.count)).squareRoot()
    }

    /// 全部可变状态都在内部串行队列上访问（识别回调来自任意线程）
    private final class State {
        let queue = DispatchQueue(label: "com.voicepolish.chunked-asr")
        let maxConcurrent: Int
        let samples: [Float]
        let ranges: [Range<Int>]
        let transcribeChunk: ChunkTranscriber
        let completion: (Result<String, Error>) -> Void

        var results: [String?]
        var nextIndex = 0
        var inFlight = 0
        var finishedCount = 0
        var retriedIndexes: Set<Int> = []
        var didComplete = false

        init(chunkCount: Int, maxConcurrent: Int, samples: [Float], ranges: [Range<Int>],
             transcribeChunk: @escaping ChunkTranscriber, completion: @escaping (Result<String, Error>) -> Void) {
            self.maxConcurrent = maxConcurrent
            self.samples = samples
            self.ranges = ranges
            self.transcribeChunk = transcribeChunk
            self.completion = completion
            self.results = Array(repeating: nil, count: chunkCount)
        }

        func fillSlots() {
            while inFlight < maxConcurrent && nextIndex < ranges.count && !didComplete {
                launch(index: nextIndex)
                nextIndex += 1
            }
        }

        func launch(index: Int) {
            inFlight += 1
            let chunk = Array(samples[ranges[index]])
            // 强持有 self：State 没有外部持有者，靠在途回调钉住自己；
            // 用 weak 会在请求发出后立刻释放、回调全部落空（同 transcribeSync 内的教训）。
            transcribeChunk(index, chunk) { result in
                self.queue.async { self.handle(index: index, result: result) }
            }
        }

        func handle(index: Int, result: Result<String, Error>) {
            inFlight -= 1
            switch result {
            case .success(let text):
                store(index: index, text: text)
            case .failure(let error):
                let asrError = error as? CloudASRTranscriber.TranscriptionError
                if case .noSpeech? = asrError {
                    // 无语音：先记空，全部完成后按能量决定是否并段恢复
                    store(index: index, text: "")
                    return
                }
                if let e = asrError, e.isRetriableInPlace, !retriedIndexes.contains(index) {
                    retriedIndexes.insert(index)
                    launch(index: index)
                    return
                }
                finish(with: .failure(error))
            }
        }

        func store(index: Int, text: String) {
            results[index] = text
            finishedCount += 1
            if finishedCount == ranges.count {
                startRecoveryOrFinish()
            } else {
                fillSlots()
            }
        }

        /// 并行识别全部完成后：把「空但有能量」的段并回相邻存活段重识别，再拼接。
        func startRecoveryOrFinish() {
            let floor = ChunkedASRCoordinator.noiseFloor(samples: samples)
            let targets = (0..<ranges.count).filter { i in
                (results[i] ?? "").isEmpty &&
                ChunkedASRCoordinator.segmentRMS(samples: samples, range: ranges[i]) > floor * ChunkedASRCoordinator.recoveryEnergyFactor
            }
            recoverNext(targets: targets, cursor: 0)
        }

        /// 顺序处理待恢复段：并入相邻存活段（优先前一段，否则后一段）重识别。
        func recoverNext(targets: [Int], cursor: Int) {
            guard cursor < targets.count else {
                let joined = TranscriptJoiner.join(results.compactMap { $0 })
                finish(with: .success(joined))
                return
            }
            let i = targets[cursor]
            // 若已被前一次恢复合并进邻段（本段仍空、邻段已扩），跳过
            guard let neighbor = survivingNeighbor(of: i) else {
                recoverNext(targets: targets, cursor: cursor + 1)
                return
            }
            let lo = min(ranges[neighbor].lowerBound, ranges[i].lowerBound)
            let hi = max(ranges[neighbor].upperBound, ranges[i].upperBound)
            let merged = Array(samples[lo..<hi])
            transcribeChunk(neighbor, merged) { result in
                self.queue.async {
                    // 调用方取消了：剩下的段不再恢复，整体按失败收尾（优3）
                    if case .failure(let error) = result, CloudASRTranscriber.isCancellation(error) {
                        self.finish(with: .failure(error))
                        return
                    }
                    if case .success(let text) = result, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.results[neighbor] = text
                        self.results[i] = ""   // 内容已并入 neighbor
                    }
                    // 恢复失败则保持原样（邻段原文 + 本段空），绝不比原来更差
                    self.recoverNext(targets: targets, cursor: cursor + 1)
                }
            }
        }

        /// 找 i 的相邻存活段（有文本的）：先前一段、再后一段。
        func survivingNeighbor(of i: Int) -> Int? {
            var p = i - 1
            while p >= 0 {
                if !(results[p] ?? "").isEmpty { return p }
                p -= 1
            }
            var n = i + 1
            while n < ranges.count {
                if !(results[n] ?? "").isEmpty { return n }
                n += 1
            }
            return nil
        }

        /// 只回调一次；失败后已在途的段照常结束但结果被忽略
        func finish(with result: Result<String, Error>) {
            guard !didComplete else { return }
            didComplete = true
            completion(result)
        }
    }
}

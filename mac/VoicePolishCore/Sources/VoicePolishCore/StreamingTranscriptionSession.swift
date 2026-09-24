import Foundation

/// 边录边发：录音进行中就把「已说完、后面接着停顿」的段落提交识别，松手时只剩最后一小段要识别，
/// 从而让长录音「松手→出字」的等待基本恒定，不再随录音时长增长。
///
/// 设计（串行提交，简单可靠）：
/// - 录音中定期 ingest(整段快照)。在 [已提交位置, 活边缘-安全边距] 内找停顿，凑够 ~9s 就提交一段；
///   同一时刻只允许一段在途（识别 ~2s 足以跟上语速），避免复杂的乱序与并发。
/// - 某段识别为空/无语音 → 不推进已提交位置，这段音频自然并入下一段（前向合并），绝不丢内容。
/// - finish(最终整段) 时：等在途段完成，再把剩余尾巴走 tailTranscriber（末尾分段+无语音恢复），
///   与前面已识别的文字按顺序拼接。
/// - 全程无停顿（连续说话）→ 录音中不提交，退化为「松手后整段识别」，与原行为一致。
public final class StreamingTranscriptionSession {

    /// 识别一段音频（录音中提交用；单段、已是合理大小）
    public typealias ChunkTranscriber = (_ samples: [Float], _ completion: @escaping (Result<String, Error>) -> Void) -> Void
    /// 识别尾巴（松手时用；可能较长，走末尾自动分段+恢复）
    public typealias TailTranscriber = (_ samples: [Float], _ completion: @escaping (Result<String, Error>) -> Void) -> Void

    public static let sampleRate = 16000
    static let liveMarginSeconds = 1.5    // 不在活边缘 1.5s 内下刀（那里可能正在说）
    static let targetCommitSeconds = 6.0  // 每段目标时长（越小→松手时尾巴越小；2.0 按时长计费，切多不多花钱）
    static let minCommitSeconds = 3.5     // 小于此不单独提交
    static let searchRadiusSeconds = 4.5  // 在 目标点 ± 此范围 内找停顿

    private let queue = DispatchQueue(label: "com.voicepolish.streaming-asr")
    private let chunkTranscriber: ChunkTranscriber
    private let tailTranscriber: TailTranscriber
    public var debugLog: ((String) -> Void)?

    /// 测试观测钩子：每段录音中提交处理完后触发，参数为当前已提交样本位置。生产环境不设置。
    var onCommitProcessed: ((Int) -> Void)?
    /// 已提交样本位置（测试断言用）
    var committedIndexForTest: Int { queue.sync { committedIndex } }

    private var committedIndex = 0        // 此前的音频都已识别、文字已入 texts
    private var committedTexts: [String] = []
    private var committing = false        // 是否有一段在途
    private var lastEmptyCut = -1         // 上次提交返回空的切点（下次要越过它）
    private var finished = false
    private var pendingFinish: (finalSamples: [Float], completion: (Result<String, Error>) -> Void)?

    public init(chunkTranscriber: @escaping ChunkTranscriber, tailTranscriber: @escaping TailTranscriber) {
        self.chunkTranscriber = chunkTranscriber
        self.tailTranscriber = tailTranscriber
    }

    /// 录音中定期调用，传入「从开始到现在」的完整样本快照。
    public func ingest(snapshot: [Float]) {
        queue.async { self.tryCommit(snapshot: snapshot) }
    }

    /// 松手时调用，传入最终完整样本；识别尾巴并拼接，通过 completion 返回全文原始识别结果。
    public func finish(finalSamples: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            self.finished = true
            if self.committing {
                // 有段在途：等它回来再收尾（见 handleCommitResult）
                self.pendingFinish = (finalSamples, completion)
                return
            }
            self.runFinish(finalSamples: finalSamples, completion: completion)
        }
    }

    // MARK: - 提交（录音中）

    private func tryCommit(snapshot: [Float]) {
        guard !finished, !committing else { return }
        let sr = Double(Self.sampleRate)
        let liveEnd = snapshot.count - Int(Self.liveMarginSeconds * sr)
        let minChunk = Int(Self.minCommitSeconds * sr)
        guard liveEnd - committedIndex >= minChunk else { return }

        // 用整段快照算停顿（floor/speech 更稳），再筛到可提交窗口
        let candidates = AudioChunker.pauseCandidates(samples: snapshot)
        guard !candidates.isEmpty else { return }

        let target = committedIndex + Int(Self.targetCommitSeconds * sr)
        let cut = candidates
            .map { $0.centerSample }
            .filter { $0 > lastEmptyCut && $0 - committedIndex >= minChunk && $0 <= liveEnd }
            .min { abs($0 - target) < abs($1 - target) }
        guard let cut = cut else { return }

        committing = true
        let chunk = Array(snapshot[committedIndex..<cut])
        let from = committedIndex
        log("stream commit [\(String(format: "%.1f", Double(from)/sr))-\(String(format: "%.1f", Double(cut)/sr))s]")
        chunkTranscriber(chunk) { result in
            self.queue.async { self.handleCommitResult(cut: cut, result: result) }
        }
    }

    private func handleCommitResult(cut: Int, result: Result<String, Error>) {
        committing = false
        switch result {
        case .success(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            committedTexts.append(text)
            committedIndex = cut
            lastEmptyCut = -1
        default:
            // 空/无语音/失败：不推进，这段音频并入后续（前向合并）；越过此切点避免反复选它
            lastEmptyCut = cut
            log("stream commit empty/failed, will merge forward")
        }
        onCommitProcessed?(committedIndex)
        // 若收尾在等在途段，现在补做
        if let pending = pendingFinish {
            pendingFinish = nil
            runFinish(finalSamples: pending.finalSamples, completion: pending.completion)
        }
    }

    // MARK: - 收尾（松手）

    private func runFinish(finalSamples: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        let start = min(committedIndex, finalSamples.count)
        let tail = Array(finalSamples[start..<finalSamples.count])
        let committed = committedTexts
        log("stream finish: 已提交\(committed.count)段, 尾巴\(String(format: "%.1f", Double(tail.count)/Double(Self.sampleRate)))s")

        // 尾巴为空（极少见：全部已提交且刚好切到末尾）→ 直接返回已提交文字
        guard !tail.isEmpty else {
            completion(.success(Self.join(committed)))
            return
        }

        tailTranscriber(tail) { result in
            self.queue.async {
                switch result {
                case .success(let tailText):
                    completion(.success(Self.join(committed + [tailText])))
                case .failure(let error):
                    // 尾巴判定为无语音（松手前的静音）→ 已提交内容就是全文。
                    // 其它失败绝不能只返回已提交部分——那会静默吞掉句尾；
                    // 如实报错，上层会退回整段重识别（AppDelegate.stopRecordingAndProcess）。
                    if case CloudASRTranscriber.TranscriptionError.noSpeech = error, !committed.isEmpty {
                        completion(.success(Self.join(committed)))
                    } else {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined()
    }

    private func log(_ msg: String) { debugLog?(msg) }
}

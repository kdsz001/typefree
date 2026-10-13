import Foundation

/// 平台无关的语音处理流水线：录音样本 → 识别 → 润色 → 最终文本
/// macOS 的 AppDelegate 和 iOS 的 KeyboardViewController 都调用这个类
public final class VoicePolishPipeline {

    /// 流水线状态，用于 UI 更新回调
    public enum State {
        case transcribing(message: String)
        case polishing(message: String)
        case done(text: String)
        case error(message: String)
        case empty  // 没有识别到内容
    }

    /// 回调闭包
    public var onStateChange: ((State) -> Void)?
    public var debugLog: ((String) -> Void)?

    /// 润色失败但仍输出了未润色文字时触发，参数为人话原因（如额度用尽）。
    /// 用于提醒用户"本次没润色 + 为什么"，避免额度耗尽被静默跳过（文字照常输出，不丢）。
    public var onPolishFailed: ((_ reason: String) -> Void)?

    /// 本次按某种目标语言输出时触发（在 .done 之前）。command 非 nil = 语音口令触发；nil = 默认输出语言。
    public var onOutputLanguageApplied: ((_ language: OutputLanguage, _ command: OutputLanguageCommand?) -> Void)?

    /// 可注入的音频保存器：把样本存档并返回音频文件名（如 "<id>.m4a"），失败/不保存返回 nil。
    /// macOS 设置它以保留历史音频；iOS 留 nil（不保留）。是否真正保存由调用方（含"保留音频"开关）决定。
    public var audioSaver: ((_ samples: [Float], _ id: String) -> String?)?

    /// 正在处理的这一次（用 entryID 当令牌）。取消 / 超时放弃后置空，之后晚到的识别、润色结果一律丢掉，
    /// 不再回调 UI、不写历史——工单 #1024：网络卡住时用户按 Esc 或等到超时，旧结果不能过几分钟又冒出来打字。
    private var activeEntryID: String?
    private let activeLock = NSLock()

    // 依赖的组件
    private let aiPolisher: AIPolisher
    private let cloudTranscriber: CloudASRTranscriber
    private let omniTranscriber: OmniTranscriber

    public init(
        aiPolisher: AIPolisher,
        cloudTranscriber: CloudASRTranscriber,
        omniTranscriber: OmniTranscriber? = nil
    ) {
        self.aiPolisher = aiPolisher
        self.cloudTranscriber = cloudTranscriber
        self.omniTranscriber = omniTranscriber ?? OmniTranscriber()
    }

    // MARK: - 取消

    /// 放弃正在处理的这一次：之后它的结果都不再回调、不写历史。返回是否真的有一次在处理。
    @discardableResult
    public func cancelCurrent() -> Bool {
        activeLock.lock(); defer { activeLock.unlock() }
        let had = activeEntryID != nil
        activeEntryID = nil
        return had
    }

    private func begin(_ entryID: String) {
        activeLock.lock(); activeEntryID = entryID; activeLock.unlock()
    }

    private func isActive(_ entryID: String) -> Bool {
        activeLock.lock(); defer { activeLock.unlock() }
        return activeEntryID == entryID
    }

    /// 只有还在处理的那一次才回调 UI；结束态（done/error/empty）回调后这一次就算结束
    private func emit(_ state: State, _ entryID: String) {
        guard isActive(entryID) else {
            log("Pipeline result dropped (cancelled): \(Self.stateName(state))")
            return
        }
        switch state {
        case .done, .error, .empty: _ = cancelCurrent()
        case .transcribing, .polishing: break
        }
        onStateChange?(state)
    }

    private static func stateName(_ state: State) -> String {
        switch state {
        case .transcribing: return "transcribing"
        case .polishing: return "polishing"
        case .done: return "done"
        case .error: return "error"
        case .empty: return "empty"
        }
    }

    // MARK: - 主入口

    /// 处理录音样本，完成后通过 onStateChange 回调
    public func process(samples: [Float], mode: ProcessingMode) {
        let pipelineStart = Date()

        guard !samples.isEmpty else {
            log("No audio samples!")
            onStateChange?(.empty)
            return
        }

        let entryID = UUID().uuidString  // 该条历史的稳定 ID，音频文件与日志共用
        begin(entryID)
        log("Pipeline started: mode=\(mode.debugName), samples=\(samples.count) (\(String(format: "%.1f", Float(samples.count) / 16000.0))s)")
        emit(.transcribing(message: mode.transcriptionOverlayMessage), entryID)

        transcribe(samples: samples, using: mode, pipelineStart: pipelineStart, entryID: entryID)
    }

    /// 边录边发专用入口：识别已由外部（StreamingTranscriptionSession）完成，
    /// 这里只做后半段——润色 → 术语纠正 → 回灌 UI → 存音频/写日志，与 cloudOnly 路径完全一致。
    public func processTranscribedText(_ rawText: String, samples: [Float], mode: ProcessingMode) {
        let pipelineStart = Date()
        let entryID = UUID().uuidString
        begin(entryID)
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log("Streaming produced empty text")
            emit(.empty, entryID)
            return
        }
        log("Streaming transcription done, chars=\(trimmed.count), entering polish")
        handleCloudOnlyText(rawText, mode: mode, pipelineStart: pipelineStart, samples: samples, entryID: entryID)
    }

    // MARK: - 识别

    private func transcribe(samples: [Float], using mode: ProcessingMode, pipelineStart: Date, entryID: String) {
        if mode.usesOmniDirectAudio {
            omniTranscriber.debugLog = { [weak self] msg in self?.log(msg) }
            let omniStart = Date()
            omniTranscriber.process(samples: samples) { [weak self] result in
                guard let self = self else { return }
                let elapsed = Date().timeIntervalSince(omniStart)
                switch result {
                case .success(let text):
                    self.log(String(format: "Omni produced text in %.0f ms (total since stop %.0f ms)", elapsed * 1000, Date().timeIntervalSince(pipelineStart) * 1000))
                    self.handleOmniText(text, pipelineStart: pipelineStart, samples: samples, entryID: entryID)
                case .failure(let error):
                    if case OmniTranscriber.OmniError.noAPIKey = error {
                        self.log("OmniTranscriber not configured, falling back to cloudOnly")
                        self.emit(.transcribing(message: ProcessingMode.cloudOnly.transcriptionOverlayMessage), entryID)
                        self.transcribe(samples: samples, using: .cloudOnly, pipelineStart: pipelineStart, entryID: entryID)
                        return
                    }
                    self.log("Omni failed in \(String(format: "%.1f", elapsed))s: \(error)")
                    self.emit(.error(message: "全模态识别失败"), entryID)
                }
            }
            return
        }

        // cloudOnly：从当前选择的版本开始，失败时按 极速版→标准版→2.0 兜底切换
        transcribeCloud(samples: samples,
                        version: cloudTranscriber.currentVersion(),
                        triedVersions: [],
                        inPlaceRetried: false,
                        mode: mode, pipelineStart: pipelineStart, entryID: entryID)
    }

    /// 用指定版本做云端识别，失败时按错误类型原地重试或切换到下一个版本。
    private func transcribeCloud(samples: [Float],
                                 version: CloudASRTranscriber.ASRVersion,
                                 triedVersions: Set<String>,
                                 inPlaceRetried: Bool,
                                 mode: ProcessingMode,
                                 pipelineStart: Date,
                                 entryID: String) {
        let transcribeStart = Date()
        log("Cloud ASR started (version=\(version.rawValue))")
        cloudTranscriber.transcribeAuto(samples: samples, version: version) { [weak self] result in
            guard let self = self else { return }
            let transcribeTime = Date().timeIntervalSince(transcribeStart)
            switch result {
            case .success(let rawText):
                self.log(String(format: "Cloud ASR result (version=%@): chars=%d, took %.0f ms", version.rawValue, rawText.count, transcribeTime * 1000))
                self.handleCloudOnlyText(rawText, mode: mode, pipelineStart: pipelineStart, samples: samples, entryID: entryID)
            case .failure(let error):
                self.log("Cloud ASR failed in \(String(format: "%.1f", transcribeTime))s (version=\(version.rawValue)): \(error)")
                self.handleCloudFailure(error, samples: samples, version: version, elapsed: transcribeTime,
                                        triedVersions: triedVersions, inPlaceRetried: inPlaceRetried,
                                        mode: mode, pipelineStart: pipelineStart, entryID: entryID)
            }
        }
    }

    /// 失败耗时超过这个值就不再整段原地重试
    static let inPlaceRetryMaxElapsed: TimeInterval = 20

    /// 识别失败处理：临时错误（服务器繁忙/超时）原地重试当前版本一次；否则如实报错。
    /// 不再自动切换到其它识别版本——用户选哪个就用哪个，失败就报错，绝不偷偷换模型或改默认。
    private func handleCloudFailure(_ error: Error,
                                    samples: [Float],
                                    version: CloudASRTranscriber.ASRVersion,
                                    elapsed: TimeInterval,
                                    triedVersions: Set<String>,
                                    inPlaceRetried: Bool,
                                    mode: ProcessingMode,
                                    pipelineStart: Date,
                                    entryID: String) {
        let asrError = error as? CloudASRTranscriber.TranscriptionError
        guard isActive(entryID) else {
            log("Cloud ASR failure ignored (cancelled)")
            return
        }

        // 临时性错误（服务器繁忙/超时/网络抖动）：原地重试同一版本一次（不换版本）。
        // 只重试「很快就失败」的：已经耗掉整个超时预算的再来一遍，用户要再干等一倍时间；
        // 分段识别内部对每段已各重试过一次，这里不再叠加。
        if let e = asrError, e.isRetriableInPlace, !inPlaceRetried, elapsed < Self.inPlaceRetryMaxElapsed {
            log("Transient failure, retrying same version once")
            transcribeCloud(samples: samples, version: version,
                            triedVersions: triedVersions, inPlaceRetried: true,
                            mode: mode, pipelineStart: pipelineStart, entryID: entryID)
            return
        }

        // 服务端判定无有效语音（静音 / 太短）：当作"无内容"，安静收起 + 记一条空历史，不报红框。
        if case .noSpeech? = asrError {
            log("No speech detected, treating as empty result")
            emit(.empty, entryID)
            return
        }

        // 其它失败：如实报错，不自动切换识别版本。
        let message = asrError?.errorDescription ?? "云端识别失败"
        // 识别失败的录音不论长短都留进历史（可「重试」），避免用户白说（工单 #1024：原先只留 ≥20s 的，18 秒的话就丢了）。
        if preserveFailedAttempt(samples: samples, entryID: entryID, pipelineStart: pipelineStart) {
            emit(.error(message: "\(message) · 录音已存进历史，可点「···」→「重试」"), entryID)
        } else {
            emit(.error(message: message), entryID)
        }
    }

    // MARK: - cloudOnly 后处理

    // MARK: - omni 后处理

    /// omni（音频直喂大模型）拿到的已经是成稿，但用户说的「用英文」等口令会被原样打出来。
    /// 这里对模型文本再跑一次同样的口令规则：命中就剥掉口令，再走同一条「按目标语言输出」的润色路径翻译。
    /// 只认口令，不套「默认输出语言」（omni 从来没接过这项设置，行为保持不变）。
    private func handleOmniText(_ text: String, pipelineStart: Date, samples: [Float], entryID: String) {
        let command = Self.detectOutputLanguageCommand(in: text)
        guard let plan = Self.resolveOutputLanguage(rawText: text, command: command, defaultLanguage: nil) else {
            finishProcessing(with: text, pipelineStart: pipelineStart, samples: samples, entryID: entryID)
            return
        }
        log("Omni text carries output language command, stripping and translating")
        applyOutputLanguage(plan.target, command: command, text: plan.text, rawASR: text,
                            pipelineStart: pipelineStart, samples: samples, entryID: entryID)
    }

    /// 决定本次是否要按目标语言输出：语音口令优先，其次是「默认输出语言」；返回目标语言与去掉口令后的正文。
    static func resolveOutputLanguage(rawText: String, command: OutputLanguageCommand?, defaultLanguage: OutputLanguage?) -> (target: OutputLanguage, text: String)? {
        guard let target = command?.target ?? defaultLanguage else { return nil }
        return (target, command?.strippedText ?? rawText)
    }

    /// 按目标语言输出（cloudOnly 与 omni 共用）：润色开着就交给模型「把这段用 X 写出来」；关着就只剥口令照常输出。
    private func applyOutputLanguage(_ target: OutputLanguage, command: OutputLanguageCommand?, text: String, rawASR: String,
                                     pipelineStart: Date, samples: [Float], entryID: String) {
        if let command {
            log("Output language command: \(command.matchedPhrase) (\(command.position.rawValue)) → \(target.id)")
        } else {
            log("Default output language → \(target.id)")
        }
        guard aiPolisher.isPolishEnabled() else {
            // 用户关了润色：没有模型可翻译，去掉口令后照常输出
            log("Polish disabled, output language ignored")
            finishProcessing(with: text, rawASR: rawASR, pipelineStart: pipelineStart, samples: samples, entryID: entryID)
            return
        }
        emit(.polishing(message: "→ \(target.tag)"), entryID)
        let polishStart = Date()
        aiPolisher.polishCloudASROutput(text: text, outputLanguage: target) { [weak self] result in
            guard let self = self else { return }
            let polishTime = Date().timeIntervalSince(polishStart)
            switch result {
            case .success(let polished) where !polished.isEmpty:
                self.log("Output in \(target.id) done in \(String(format: "%.1f", polishTime))s, chars=\(polished.count)")
                if self.isActive(entryID) { self.onOutputLanguageApplied?(target, command) }
                self.finishProcessing(with: polished, rawASR: rawASR, pipelineStart: pipelineStart, samples: samples, entryID: entryID)
            case .success:
                self.finishProcessing(with: text, rawASR: rawASR, pipelineStart: pipelineStart, samples: samples, entryID: entryID)
            case .failure(let err):
                self.log("Output in \(target.id) failed in \(String(format: "%.1f", polishTime))s: \(err), fallback to original")
                if case AIPolisher.PolishError.noAPIKey = err {} else if self.isActive(entryID) {
                    let reason = (err as? LocalizedError)?.errorDescription ?? "\(err)"
                    self.onPolishFailed?(reason)
                }
                self.finishProcessing(with: text, rawASR: rawASR, pipelineStart: pipelineStart, samples: samples, entryID: entryID)
            }
        }
    }

    // MARK: - cloudOnly 后处理

    private func handleCloudOnlyText(_ rawText: String, mode: ProcessingMode, pipelineStart: Date, samples: [Float], entryID: String) {
        // 目标语言：语音口令（句首/句尾「用英文」「翻译成日文」等）优先，其次是设置里的「默认输出语言」。
        // 口令由程序规则识别，不交给模型领会；模型只负责「把这段用 X 写出来」。
        let command = Self.detectOutputLanguageCommand(in: rawText)
        if let plan = Self.resolveOutputLanguage(rawText: rawText, command: command, defaultLanguage: OutputLanguage.defaultLanguage()) {
            applyOutputLanguage(plan.target, command: command, text: plan.text, rawASR: rawText,
                                pipelineStart: pipelineStart, samples: samples, entryID: entryID)
            return
        }

        let charCount = aiPolisher.meaningfulCharacterCount(in: rawText)
        if charCount <= 10 {
            let output = stripTrailingPunctuationIfSingleSentence(rawText)
            log("Cloud-only short text (\(charCount) chars), direct output chars=\(output.count)")
            finishProcessing(with: output, rawASR: rawText, pipelineStart: pipelineStart, samples: samples, entryID: entryID)
            return
        }

        if !aiPolisher.isPolishEnabled() {
            let output = stripTrailingPunctuationIfSingleSentence(rawText)
            log("Polish disabled by user (provider=none), output chars=\(output.count)")
            finishProcessing(with: output, rawASR: rawText, pipelineStart: pipelineStart, samples: samples, entryID: entryID)
            return
        }

        log("Cloud-only long text (\(charCount) chars), polishing")
        emit(.polishing(message: mode.polishOverlayMessage), entryID)
        let polishStart = Date()
        aiPolisher.polishCloudASROutput(text: rawText) { [weak self] result in
            guard let self = self else { return }
            let polishTime = Date().timeIntervalSince(polishStart)
            switch result {
            case .success(let polished):
                let finalText = polished.isEmpty ? rawText : polished
                self.log("Cloud ASR polish done in \(String(format: "%.1f", polishTime))s, output chars=\(finalText.count)")
                self.finishProcessing(with: finalText, rawASR: rawText, pipelineStart: pipelineStart, samples: samples, entryID: entryID)
            case .failure(let err):
                self.log("Cloud ASR polish failed in \(String(format: "%.1f", polishTime))s: \(err), fallback to raw")
                // 润色失败：文字照常输出（不丢用户的话），但提醒一次"没润色 + 原因"。
                // noAPIKey（用户选了不润色/没配 key）是正常状态，不提醒；其余（额度/欠费/网络/限流）都提醒。
                // 例外：没选「不优化」、只是没填润色 Key 且试用已结束的人，每天提醒一次，不然他不知道为什么文字没整理。
                if !self.isActive(entryID) {
                    // 已取消：不提醒，finishProcessing 里也会丢掉
                } else if case AIPolisher.PolishError.noAPIKey = err {
                    if let hint = Self.dailyPolishUnconfiguredHint() { self.onPolishFailed?(hint) }
                } else {
                    let reason = (err as? LocalizedError)?.errorDescription ?? "\(err)"
                    self.onPolishFailed?(reason)
                }
                self.finishProcessing(with: rawText, pipelineStart: pipelineStart, samples: samples, entryID: entryID)
            }
        }
    }

    /// 试用结束 / 不是会员、又没填润色 Key、也没主动选「不优化」：每天最多提醒一次「润色未配置」。
    static func dailyPolishUnconfiguredHint(now: Date = Date()) -> String? {
        let config = VoicePolishConfig.shared
        guard !AIPolisher.isPolishDisabled(provider: config.string(forKey: "polish_provider")) else { return nil }
        guard TrialManager.shared.trialExpired, !LicenseManager.shared.hasActiveMembership() else { return nil }
        let key = "polishUnconfiguredHintDay"
        let day = TrialManager.beijingDayKey(now: now)
        guard UserDefaults.standard.string(forKey: key) != day else { return nil }
        UserDefaults.standard.set(day, forKey: key)
        return "润色未配置，已输出原文 · 在「设置 → 模型」填润色 Key，或开通会员"
    }

    /// 口令总开关（output_language_command_enabled，默认开）+ 设置里的语言列表（触发词/开关可改）
    static func detectOutputLanguageCommand(in text: String) -> OutputLanguageCommand? {
        let config = VoicePolishConfig.shared
        guard config.bool(forKey: OutputLanguage.commandEnabledConfigKey, defaultValue: true) else { return nil }
        return OutputLanguageCommand.detect(in: text, languages: OutputLanguage.configured(config: config))
    }

    // MARK: - 完成处理

    private func finishProcessing(with finalText: String?, rawASR: String? = nil, pipelineStart: Date, samples: [Float], entryID: String) {
        guard isActive(entryID) else {
            log("Pipeline result dropped (cancelled): done")
            return
        }
        guard let finalText = finalText, !finalText.isEmpty else {
            log(String(format: "Pipeline took %.0f ms, no output", Date().timeIntervalSince(pipelineStart) * 1000))
            emit(.empty, entryID)
            return
        }

        // 应用术语纠正
        let correctedText = aiPolisher.applyConfiguredTermCorrections(to: finalText)
        if correctedText != finalText {
            log("Term corrections applied: before chars=\(finalText.count), after chars=\(correctedText.count)")
        }

        let durationMs = Int(Date().timeIntervalSince(pipelineStart) * 1000)

        // 先把文本回灌给 UI（粘贴即时），再后台存音频 + 写日志，避免编码拖慢粘贴。
        log(String(format: "Pipeline completed in %.0f ms", Double(durationMs)))
        emit(.done(text: correctedText), entryID)

        let savedASR = rawASR ?? correctedText
        let saver = audioSaver
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let audioFile = saver?(samples, entryID)  // nil = 不保留音频（开关关 / iOS / 编码失败）
            self.aiPolisher.writePolishLog(
                asr: savedASR,
                output: correctedText,
                durationMs: durationMs,
                id: entryID,
                audioFile: audioFile
            )
        }
    }

    /// 识别失败时，把音频留进历史并标记为可重试，避免用户白录。返回是否会保留（有 audioSaver）。
    /// 依赖 audioSaver（macOS 有、iOS 为 nil）；编码失败 / 关闭保留 则不留。
    @discardableResult
    private func preserveFailedAttempt(samples: [Float], entryID: String, pipelineStart: Date) -> Bool {
        guard let saver = audioSaver else { return false }
        let durationMs = Int(Date().timeIntervalSince(pipelineStart) * 1000)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard let audioFile = saver(samples, entryID) else { return }
            self.aiPolisher.writePolishLog(
                asr: "",
                output: "（这段录音识别失败，点右侧「···」→「重试」可重新识别）",
                durationMs: durationMs,
                id: entryID,
                audioFile: audioFile
            )
            self.log("Preserved failed recording to history (\(audioFile)) for retry")
        }
        return true
    }

    /// 调用方放弃了这次识别（总等待封顶到点）：录音另存一条「识别失败、可重试」的历史。返回是否会保留。
    /// 调用方应先 cancelCurrent()，免得这一次过后又自己写一条。
    public func preserveFailedRecording(samples: [Float], startedAt: Date) -> Bool {
        preserveFailedAttempt(samples: samples, entryID: UUID().uuidString, pipelineStart: startedAt)
    }

    // MARK: - 工具方法

    /// 短文本直出时去掉末尾断句标点，聊天场景更自然
    private func stripTrailingPunctuationIfSingleSentence(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, "。".contains(last) {
            result.removeLast()
        }
        return result
    }

    private func log(_ message: String) {
        debugLog?(message)
    }
}

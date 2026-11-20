import Foundation

/// Mac 录音主流程里几处「多长算误触 / 该提示什么」的规则，抽成纯函数便于单测（2026-11-19 体检）。
public enum RecordingFlowPolicy {

    // MARK: - 录音被判「没声音」（体检 修1）

    /// 录满这么久还被判没声音，就不再当误触悄悄收起：多半是麦克风没收到声音（选错设备、耳机切换），
    /// 或识别服务把「短句 + 尾随静音」误判成无语音。短于它的（误触、按一下就松）照旧安静收起。
    public static let silentReportMinSeconds: Double = 3

    public static func shouldReportSilence(audioSeconds: Double) -> Bool {
        audioSeconds >= silentReportMinSeconds
    }

    /// 没声音时给用户的话；录音真的存进历史了才说「已存进历史」（关了保存历史 / 加密不可用时不能这么说）。
    /// captureInterrupted：录音中换麦克风后采集没接上（体检 优10），原因说得更具体。
    public static func silentRecordingHint(savedToHistory: Bool, captureInterrupted: Bool = false) -> String {
        let reason = captureInterrupted ? "录音中麦克风断开了，没录到声音 · 请检查麦克风" : "没听到声音，请检查麦克风"
        return savedToHistory ? reason + " · 录音已存进历史，可点「···」→「重试」" : reason
    }

    // MARK: - 录音中换麦克风后采集没接上（体检 优10）

    /// 录音胶囊上短暂显示的字（胶囊窄，最多放 4 个字）
    public static let captureInterruptedCaption = "设备断开"
    /// 照常出字后补的一句：断开之后说的话没录上
    public static let captureInterruptedHint = "录音中麦克风断开了，后面的话可能没录上 · 请检查麦克风"

    // MARK: - 润色阶段的总等待封顶（体检 优10）
    //
    // 识别完、润色时网络卡住，以前要白等润色请求自己超时（自带 Key / 会员 60 秒，试用 30 秒 + 换令牌重试）才出原文。
    // 依据：2026-07 用 Ray 1346 条录音日志复盘，润色约 0.8 秒起步、每 100 字约 1 秒（680 字 ≈ 7.8 秒）；
    // 本机 2026-11 日志 13 次润色 1.2–2.4 秒（14–90 字）。封顶给 25 秒底 + 每字 0.03 秒（按 3 倍于实测的速度算），
    // 最多 90 秒：100 字 28 秒、680 字 45 秒、2000 字以上 85–90 秒——正常的慢润色都掐不到，只截住真卡住的。

    public static func polishWaitCap(characters: Int) -> TimeInterval {
        min(90, 25 + Double(max(0, characters)) * 0.03)
    }

    /// 等太久放弃润色时，照现有方式提醒「已输出未润色文字（润色失败：…）」里的原因
    /// （放弃本身由 VoicePolishPipeline.giveUpPolishing 做，走它「润色失败」的同一段收尾）
    public static func polishTimeoutReason(cap: TimeInterval) -> String {
        "网络太慢，等了 \(Int(cap.rounded())) 秒没整理完"
    }

    // MARK: - 试用到期那一刻的长录音（体检 优10）
    //
    // 录音中途试用到期：先发出去的段落拿到「试用已结束」后本机清掉了试用令牌，后面的段落就被当成
    // 「没配 Key」，最后报出「未配置云端语音识别凭证」——用户根本没打算配 Key，这句话是错的。

    public static let trialEndedMessage = "试用已结束 · 开通会员，或在「设置 → 模型」填自己的 Key"
    public static let trialEndedPartialHint = "试用已结束，后半段没识别出来 · 开通会员，或在「设置 → 模型」填自己的 Key"

    /// 这次录音是不是「开始时还在试用、处理时试用已经结束」：没填自己的 Key、也没激活（激活的会员走另一套）
    public static func trialEndedDuringRecording(startedInTrial: Bool, trialExpiredNow: Bool,
                                                 ownKeyConfigured: Bool, activated: Bool) -> Bool {
        startedInTrial && trialExpiredNow && !ownKeyConfigured && !activated
    }

    /// 识别失败的提示：试用正好在这次录音里到期、报的又是「未配置凭证」时，换成「试用已结束」（后缀如「录音已存进历史」保留）
    public static func recognitionErrorMessage(_ message: String, trialEndedDuringRecording: Bool) -> String {
        guard trialEndedDuringRecording,
              let missing = CloudASRTranscriber.TranscriptionError.missingCredentials.errorDescription,
              message.hasPrefix(missing) else { return message }
        return trialEndedMessage + message.dropFirst(missing.count)
    }

    /// 是不是「未配置凭证」这一种识别错误
    public static func isMissingCredentials(_ error: Error) -> Bool {
        if case CloudASRTranscriber.TranscriptionError.missingCredentials? = error as? CloudASRTranscriber.TranscriptionError { return true }
        return false
    }
}

import Cocoa
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension Notification.Name {
    static let voicePolishTermCorrectionsDidChange = Notification.Name("VoicePolishTermCorrectionsDidChange")
}

/// 术语纠正自动学习：粘贴文字后监控输入框变化，用户改对了识别错的词，就把改对的词加进词库当热词。
///
/// 2026-09-23（工单 #1013，Ray 拍板 A 方案）：改一次就学，只加词、不再生成「错法 → 正写」强制替换规则；
/// 选词、限量、撤销的规则在 VoicePolishCore/VocabularyLearning（照火山官方热词最佳实践）。
/// 下面的 requiredLearnCount / 候选（candidates）逻辑只剩老数据清理在用，学词不再走它。
///
/// 安全策略：
/// - 只对比"投递文字"区间内的改动，忽略输入框中其他内容的变化
/// - 只记录短术语替换，不学整段句子
/// - 新旧词长度比例不能差太大（防止误学删除/大段重写）
/// - 纯标点、纯数字变化忽略
/// - 只学读音相近的替换（MishearingCheck）：读音不像的是在改内容，学成全局替换会把以后正确的字改错
/// - 候选 30 天内没再出现就作废，免得偶然的两次改内容凑成一条规则
final class HotWordsAutoLearner {
    private struct Token {
        let text: String
        let range: Range<String.Index>
    }

    private struct LearnedTermCorrection {
        let target: String
        let variant: String
    }

    private struct StoredTermCorrection {
        let target: String
        var variants: [String]
        var category: String
        var source: String   // "auto" = 自动学习学到；其余视为手动添加
    }

    private struct PendingLearnedCorrection {
        let target: String
        let variant: String
        var count: Int
        var lastSeen: String   // yyyy-MM-dd
    }

    private struct PersistedCorrections {
        let added: [String]
        let pending: [String]
    }

    static let shared = HotWordsAutoLearner()

    private let config = VoicePolishConfig.shared
    private var monitorTimer: Timer?
    private var preparedElement: AXUIElement?
    private var pendingStartWorkItem: DispatchWorkItem?
    private var deliveredText: String?
    private var targetElement: AXUIElement?
    private var initialValue: String?
    private var deliveredRange: Range<String.Index>?  // 投递文字在输入框中的位置
    private var monitorStartTime: Date?
    private var pendingEditedSegment: String?
    /// 这次监控里输入框内容的每一版（按时间顺序）。只看最后一版不够：飞书里改完一个字半秒后，
    /// 输入框会多出一段文字插在光标附近（Ray 9-23 实测 11→29 字），最后一版判不出「李→吕」，
    /// 刚改完那一版是干净的。定稿时最后一版判不出来，就往前找。
    private var editedSnapshots: [String] = []
    private var pendingEditedAt: Date?
    private var lastLearnedSegment: String?

    /// 监控时长（秒）
    private let monitorDuration: TimeInterval = 60

    /// 读前台 App 输入框的单次跨进程超时（体检 优10）。以前没设、用系统全局默认值（头文件没写具体秒数，常见说法约 6 秒）：
    /// 对方 App 卡住时，主线程每 0.5 秒被拖住一次。超时只对设过的那个元素对象生效、不会传给它的子元素，所以每个元素都要设。
    /// 正常读取都是毫秒级；给 1 秒而不是出字那条路的 0.25 秒（TextDelivery.axTimeout）——网页类 App 读大段文字偶尔慢，
    /// 别因为超时太紧少学词。超时 = 读不到，按现有「输入框不可读 → 停止监控」处理。
    private static let axTimeout: Float = 1.0

    /// 修正词最短长度（允许单字纠正，如 "向"→"相"）
    private let minCorrectionLength = 1

    /// 修正词最长长度（超过的不学，太长大概率已经是整句）
    private let maxCorrectionLength = 12

    /// 同一条修正至少出现两次，才正式生效
    private let requiredLearnCount = 2

    /// 候选多少天没再出现就作废
    private let candidateLifetimeDays = 30

    /// 编辑停止多久后，认为这段文字已经定稿
    private let idleFinalizeDelay: TimeInterval = 4

    /// 粘贴后读不到输入框（或还没读到刚粘进去的文字）时再试几次。2026-09-23 实测约一天 70 次出字只有 44 次盯上，
    /// ChatGPT、Notion 这类网页 App 粘贴后要过一会儿才能从辅助功能读到新文字，原先只试一次就放弃了。
    private let startRetryCount = 3
    private let startRetryDelay: TimeInterval = 0.5

    var debugLog: ((String) -> Void)?
    var onLearned: (([String]) -> Void)?
    var onLearningCandidate: (([String]) -> Void)?

    private init() {}

    // MARK: - 开始监控

    func prepareForDelivery() {
        guard AXIsProcessTrusted() else { return }
        preparedElement = getFocusedTextElement()
    }

    func startMonitoring(deliveredText: String) {
        let preparedElement = self.preparedElement
        stopMonitoring()
        self.preparedElement = preparedElement

        guard AXIsProcessTrusted() else {
            debugLog?("AutoLearn: 无辅助功能权限，跳过监控")
            return
        }

        attemptStartMonitoring(deliveredText: deliveredText, attemptsRemaining: startRetryCount)
    }

    private func attemptStartMonitoring(deliveredText: String, attemptsRemaining: Int) {
        let focusedElement = getFocusedTextElement() ?? preparedElement
        guard let focusedElement else {
            retryStartMonitoring(deliveredText: deliveredText, attemptsRemaining: attemptsRemaining, reason: "未找到焦点输入框")
            return
        }

        guard let currentValue = getElementValue(focusedElement) else {
            retryStartMonitoring(deliveredText: deliveredText, attemptsRemaining: attemptsRemaining, reason: "无法读取输入框内容")
            return
        }

        guard let range = currentValue.range(of: deliveredText, options: .backwards) else {
            retryStartMonitoring(deliveredText: deliveredText, attemptsRemaining: attemptsRemaining, reason: "输入框中未找到投递文字")
            return
        }

        self.deliveredText = deliveredText
        AXUIElementSetMessagingTimeout(focusedElement, Self.axTimeout)   // 之后每 0.5 秒都读它，同样不能被卡住的 App 拖住
        self.targetElement = focusedElement
        self.initialValue = currentValue
        self.deliveredRange = range
        self.monitorStartTime = Date()

        debugLog?("AutoLearn: 开始监控，投递字数=\(deliveredText.count)")

        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }

    private func retryStartMonitoring(deliveredText: String, attemptsRemaining: Int, reason: String) {
        guard attemptsRemaining > 1 else {
            debugLog?("AutoLearn: \(reason)，放弃本次监控")
            return
        }

        debugLog?("AutoLearn: \(reason)，稍后重试")

        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptStartMonitoring(deliveredText: deliveredText, attemptsRemaining: attemptsRemaining - 1)
        }
        pendingStartWorkItem?.cancel()
        pendingStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + startRetryDelay, execute: workItem)
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        pendingStartWorkItem?.cancel()
        pendingStartWorkItem = nil
        preparedElement = nil
        deliveredText = nil
        targetElement = nil
        initialValue = nil
        deliveredRange = nil
        monitorStartTime = nil
        pendingEditedSegment = nil
        editedSnapshots = []
        pendingEditedAt = nil
        lastLearnedSegment = nil
    }

    func finalizePendingLearning(reason: String) {
        finalizePendingCorrections(reason: reason)
    }

    /// 手动纠正：对比原始输出和用户修改后的文字，提取术语纠正并保存
    /// 返回这次新加进词库的词（空 = 没有值得加的新词）。
    func learnFromManualCorrection(original: String, corrected: String) -> [String] {
        debugLog?("ManualLearn: comparing originalChars=\(original.count), correctedChars=\(corrected.count)")
        // 用户在纠正框里明确教的，不做「读音相近」把关
        let corrections = extractCorrections(original: original, edited: corrected, requireSoundAlike: false)
        guard !corrections.isEmpty else {
            debugLog?("ManualLearn: no learnable corrections found")
            return []
        }
        // 提示由调用方弹：「纠正上次结果」弹「已加入词库 · 撤销」；历史记录里改字是静默学（在设置窗里，不打扰）。
        // 以前这里和调用方各弹一次，胶囊连弹两遍。
        return learnWords(corrections.map(\.target), in: corrected, reason: "manual")
    }

    /// 把改对的词加进词库（只加词、不加替换规则），返回新加的词。选词 / 限量规则见 VocabularyLearning。
    private func learnWords(_ targets: [String], in sentence: String, reason: String) -> [String] {
        // 纠错提取常是半截词（「况思远→邝思远」提取成「了邝」），先扩成完整的词再判断值不值得学
        let learnable = targets.map { VocabularyLearning.expandToWord($0, in: sentence) }
            .filter { VocabularyLearning.isLearnableWord($0) }
        let skipped = targets.count - learnable.count
        if skipped > 0 { debugLog?("AutoLearn: \(skipped) 个改动是常用词或半截词，不加进词库(\(reason))") }
        guard !learnable.isEmpty,
              let data = try? Data(contentsOf: config.configFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let entries = json["term_corrections"] as? [[String: Any]] ?? []
        let ledger = json[VocabularyLearning.ledgerKey] as? [[String: String]] ?? []
        let dismissed = json[VocabularyLearning.dismissedKey] as? [String] ?? []
        let update = VocabularyLearning.addLearnedWords(learnable, entries: entries, ledger: ledger, dismissed: dismissed,
                                                         today: VocabularyLearning.dayString())
        guard !update.added.isEmpty || update.ledger != ledger || update.dismissed != dismissed else {
            debugLog?("AutoLearn: 改对的词已在词库里或用户删过，不加(\(reason))")
            return []
        }
        if update.added.isEmpty { debugLog?("AutoLearn: 改对的词已在词库里或用户删过，不加(\(reason))") }
        config.save(values: ["term_corrections": update.entries,
                             VocabularyLearning.ledgerKey: update.ledger,
                             VocabularyLearning.dismissedKey: update.dismissed])
        NotificationCenter.default.post(name: .voicePolishTermCorrectionsDidChange, object: nil)
        if !update.added.isEmpty {
            debugLog?("AutoLearn: 加进词库 \(update.added.count) 个词\(update.evicted.isEmpty ? "" : "，挤出最早学的 \(update.evicted.count) 个")(\(reason))")
        }
        return update.added
    }

    /// 撤销刚学到的词（「已加入词库 · 撤销」）
    func undoLearnedWords(_ words: [String]) {
        guard let data = try? Data(contentsOf: config.configFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            debugLog?("UndoLearn: failed to read config")
            return
        }
        let result = VocabularyLearning.removeLearnedWords(words,
                                                           entries: json["term_corrections"] as? [[String: Any]] ?? [],
                                                           ledger: json[VocabularyLearning.ledgerKey] as? [[String: String]] ?? [])
        guard !result.removed.isEmpty else { return }
        // 撤销只删这一次，不拉黑：下次再改同样的错还会学（只有在词库页删掉的才不再学）
        config.save(values: ["term_corrections": result.entries, VocabularyLearning.ledgerKey: result.ledger])
        NotificationCenter.default.post(name: .voicePolishTermCorrectionsDidChange, object: nil)
        debugLog?("UndoLearn: removed \(result.removed.count) word(s)")
    }

    func confirmPendingCorrections(_ descriptions: [String]) -> [String] {
        let corrections = descriptions.compactMap { description -> LearnedTermCorrection? in
            let parts = description.components(separatedBy: " → ")
            guard parts.count == 2 else { return nil }
            let variant = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let target = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !variant.isEmpty, !target.isEmpty else { return nil }
            return LearnedTermCorrection(target: target, variant: variant)
        }
        guard !corrections.isEmpty else { return [] }
        return saveCorrections(corrections, requireConfirmation: false).added
    }

    private func checkForChanges() {
        if let start = monitorStartTime, Date().timeIntervalSince(start) > monitorDuration {
            finalizePendingCorrections(reason: "timeout")
            debugLog?("AutoLearn: 监控超时，停止")
            stopMonitoring()
            return
        }

        guard let element = targetElement,
              let delivered = deliveredText,
              let initial = initialValue,
              let range = deliveredRange else {
            stopMonitoring()
            return
        }

        if let focusedElement = getFocusedTextElement(),
           !isSameElement(focusedElement, element) {
            finalizePendingCorrections(reason: "focus_changed")
            debugLog?("AutoLearn: 焦点输入框已切换，停止监控")
            stopMonitoring()
            return
        }

        guard let currentValue = getElementValue(element) else {
            finalizePendingCorrections(reason: "element_unreadable")
            debugLog?("AutoLearn: 输入框不可读，停止监控")
            stopMonitoring()
            return
        }

        if currentValue == initial {
            finalizeIfIdle()
            return
        }

        // 提取投递区间外的"前缀"和"后缀"作为锚点
        let prefixAnchor = String(initial[..<range.lowerBound])
        let suffixAnchor = String(initial[range.upperBound...])

        // 用锚点在新内容中定位被修改的区间
        guard let editedSegment = extractEditedSegment(
            fullText: currentValue,
            prefixAnchor: prefixAnchor,
            suffixAnchor: suffixAnchor
        ) else {
            finalizePendingCorrections(reason: "anchor_lost")
            debugLog?("AutoLearn: 无法定位修改区间（锚点丢失），停止监控")
            stopMonitoring()
            return
        }

        debugLog?("AutoLearn: detected edit, beforeChars=\(delivered.count), afterChars=\(editedSegment.count)")

        let trimmedEditedSegment = editedSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEditedSegment.isEmpty {
            finalizePendingCorrections(reason: "segment_cleared")
            debugLog?("AutoLearn: 投递区间已清空，停止监控")
            stopMonitoring()
            return
        }

        if trimmedEditedSegment != delivered.trimmingCharacters(in: .whitespacesAndNewlines) {
            pendingEditedSegment = editedSegment
            if editedSnapshots.last != editedSegment { editedSnapshots.append(editedSegment) }
            pendingEditedAt = Date()
            debugLog?("AutoLearn: 已记录候选修改，等待定稿")
        }

        // 更新基准值继续监控
        initialValue = currentValue
        // 更新投递区间（锚点不变，中间内容变了）
        if let newRange = locateSegment(in: currentValue, prefixAnchor: prefixAnchor, suffixAnchor: suffixAnchor) {
            deliveredRange = newRange
        }
    }

    /// 用前后锚点定位修改后的区间
    private func extractEditedSegment(fullText: String, prefixAnchor: String, suffixAnchor: String) -> String? {
        let startIndex: String.Index
        if prefixAnchor.isEmpty {
            startIndex = fullText.startIndex
        } else if let prefixRange = fullText.range(of: prefixAnchor, options: .backwards) {
            startIndex = prefixRange.upperBound
        } else {
            return nil
        }

        let endIndex: String.Index
        if suffixAnchor.isEmpty {
            endIndex = fullText.endIndex
        } else if let suffixRange = fullText.range(of: suffixAnchor, range: startIndex..<fullText.endIndex) {
            endIndex = suffixRange.lowerBound
        } else {
            return nil
        }

        guard startIndex <= endIndex else { return nil }
        return String(fullText[startIndex..<endIndex])
    }

    private func locateSegment(in text: String, prefixAnchor: String, suffixAnchor: String) -> Range<String.Index>? {
        let startIndex: String.Index
        if prefixAnchor.isEmpty {
            startIndex = text.startIndex
        } else if let r = text.range(of: prefixAnchor, options: .backwards) {
            startIndex = r.upperBound
        } else {
            return nil
        }

        let endIndex: String.Index
        if suffixAnchor.isEmpty {
            endIndex = text.endIndex
        } else if let r = text.range(of: suffixAnchor, range: startIndex..<text.endIndex) {
            endIndex = r.lowerBound
        } else {
            return nil
        }

        guard startIndex <= endIndex else { return nil }
        return startIndex..<endIndex
    }

    // MARK: - 修正词提取（带上下文扩展）

    /// 提取差异时的最小上下文字符数：确保学到的替换有足够区分度
    private let minContextLength = 2

    private let pendingCorrectionsConfigKey = "term_correction_learning_candidates"

    private func extractCorrections(original: String, edited: String, requireSoundAlike: Bool = true) -> [LearnedTermCorrection] {
        let originalTokens = tokenize(original)
        let editedTokens = tokenize(edited)

        let lcs = longestCommonSubsequence(
            originalTokens.map(\.text),
            editedTokens.map(\.text)
        )

        // 收集 raw diff 段：(oldSegment tokens, newSegment tokens, LCS 左侧锚点 index, 右侧锚点 index)
        struct RawDiff {
            let oldTokens: [Token]
            let newTokens: [Token]
            let leftAnchorOI: Int?  // LCS 锚点在 originalTokens 中的 index（左侧）
            let rightAnchorOI: Int? // 右侧锚点
            let leftAnchorNI: Int?
            let rightAnchorNI: Int?
        }

        var diffs: [RawDiff] = []
        var oi = 0, ni = 0, li = 0

        while li < lcs.count {
            let anchor = lcs[li]

            var oldSegment: [Token] = []
            while oi < originalTokens.count && originalTokens[oi].text != anchor {
                oldSegment.append(originalTokens[oi])
                oi += 1
            }

            var newSegment: [Token] = []
            while ni < editedTokens.count && editedTokens[ni].text != anchor {
                newSegment.append(editedTokens[ni])
                ni += 1
            }

            if !oldSegment.isEmpty || !newSegment.isEmpty {
                let leftOI = (li > 0 && oi > 0) ? oi - oldSegment.count - 1 : nil
                let leftNI = (li > 0 && ni > 0) ? ni - newSegment.count - 1 : nil
                diffs.append(RawDiff(
                    oldTokens: oldSegment, newTokens: newSegment,
                    leftAnchorOI: leftOI, rightAnchorOI: oi < originalTokens.count ? oi : nil,
                    leftAnchorNI: leftNI, rightAnchorNI: ni < editedTokens.count ? ni : nil
                ))
            }

            if oi < originalTokens.count { oi += 1 }
            if ni < editedTokens.count { ni += 1 }
            li += 1
        }

        // 尾部
        if oi < originalTokens.count || ni < editedTokens.count {
            let oldTail = oi < originalTokens.count ? Array(originalTokens[oi...]) : []
            let newTail = ni < editedTokens.count ? Array(editedTokens[ni...]) : []
            if !oldTail.isEmpty || !newTail.isEmpty {
                let leftOI = oi > 0 ? oi - 1 : nil
                let leftNI = ni > 0 ? ni - 1 : nil
                diffs.append(RawDiff(
                    oldTokens: oldTail, newTokens: newTail,
                    leftAnchorOI: leftOI, rightAnchorOI: nil,
                    leftAnchorNI: leftNI, rightAnchorNI: nil
                ))
            }
        }

        // 对每个 diff，扩展上下文使替换词有足够区分度
        var corrections: [LearnedTermCorrection] = []
        for diff in diffs {
            let rawOld = segmentText(from: diff.oldTokens, in: original)
            let rawNew = segmentText(from: diff.newTokens, in: edited)

            let oldTrimmed = rawOld.trimmingCharacters(in: .whitespacesAndNewlines)
            let newTrimmed = rawNew.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !oldTrimmed.isEmpty, !newTrimmed.isEmpty else { continue }
            guard oldTrimmed != newTrimmed else { continue }

            // 扩展上下文：如果差异太短（如单字），向左/右拉入共同锚点使其有足够区分度
            var expandedOld = oldTrimmed
            var expandedNew = newTrimmed

            let diffCharCount = max(oldTrimmed.count, newTrimmed.count)
            if diffCharCount < minContextLength {
                // 向左扩展：拉入左侧共同锚点（如 "徐" + "向" → "徐向"）
                if let loi = diff.leftAnchorOI, let lni = diff.leftAnchorNI,
                   loi >= 0 && loi < originalTokens.count,
                   lni >= 0 && lni < editedTokens.count,
                   originalTokens[loi].text == editedTokens[lni].text {
                    let leftContext = originalTokens[loi].text
                    expandedOld = leftContext + expandedOld
                    expandedNew = leftContext + expandedNew
                }
                // 只有左边没有可用锚点时，才向右扩展
                if expandedOld.count == diffCharCount {
                    if let roi = diff.rightAnchorOI, let rni = diff.rightAnchorNI,
                       roi >= 0 && roi < originalTokens.count,
                       rni >= 0 && rni < editedTokens.count,
                       originalTokens[roi].text == editedTokens[rni].text {
                        let rightContext = originalTokens[roi].text
                        expandedOld = expandedOld + rightContext
                        expandedNew = expandedNew + rightContext
                    }
                }
            }

            if let correction = validateCorrection(old: expandedOld, new: expandedNew, requireSoundAlike: requireSoundAlike) {
                corrections.append(correction)
            }
        }

        return corrections
    }

    /// 严格验证一个替换是否可以作为术语纠正
    private func validateCorrection(old: String, new: String, requireSoundAlike: Bool) -> LearnedTermCorrection? {
        let oldTrimmed = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)

        // 没变化
        guard newTrimmed != oldTrimmed else { return nil }

        // 新词为空（纯删除）不学
        guard !newTrimmed.isEmpty else { return nil }

        // 旧词为空（纯添加）不学
        guard !oldTrimmed.isEmpty else { return nil }

        // 长度限制
        guard oldTrimmed.count <= maxCorrectionLength else { return nil }
        guard newTrimmed.count >= minCorrectionLength else { return nil }
        guard newTrimmed.count <= maxCorrectionLength else { return nil }

        // 不学整句话，只学短术语
        guard !isSentenceLike(oldTrimmed), !isSentenceLike(newTrimmed) else { return nil }

        // 不学单个英文字母/数字，避免 k -> key 这类误伤
        guard !isSingleASCIIAlphaNumeric(oldTrimmed), !isSingleASCIIAlphaNumeric(newTrimmed) else { return nil }

        // 不学单个汉字的同音/形近替换（如 他→她、在→再、的→得）：做成全局替换很危险，
        // 容易把以后本来正确的字也一起改错。带上下文的（如 徐向→徐相）会扩展成多字，不受此限。
        guard !(isSingleCJKCharacter(oldTrimmed) && isSingleCJKCharacter(newTrimmed)) else { return nil }

        // 新旧长度比不能差太大
        let ratio = Double(max(newTrimmed.count, oldTrimmed.count)) / Double(max(1, min(newTrimmed.count, oldTrimmed.count)))
        guard ratio <= 5.0 else { return nil }

        // 不记录纯标点变化
        guard !isPurelyPunctuation(newTrimmed) else { return nil }
        guard !isPurelyPunctuation(oldTrimmed) else { return nil }

        // 不记录纯数字变化
        guard !isPurelyDigits(newTrimmed) else { return nil }
        guard !isPurelyDigits(oldTrimmed) else { return nil }

        // 读音不像的是在改内容（周四→周三），不是纠正听错
        if requireSoundAlike, !MishearingCheck.isLikelyMishearing(old: oldTrimmed, new: newTrimmed) { return nil }

        return LearnedTermCorrection(target: newTrimmed, variant: oldTrimmed)
    }

    // MARK: - 辅助方法

    private func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count, n = b.count
        guard m > 0 && n > 0 else { return [] }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i-1] == b[j-1] {
                    dp[i][j] = dp[i-1][j-1] + 1
                } else {
                    dp[i][j] = max(dp[i-1][j], dp[i][j-1])
                }
            }
        }

        var result: [String] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i-1] == b[j-1] {
                result.append(a[i-1])
                i -= 1; j -= 1
            } else if dp[i-1][j] > dp[i][j-1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return result.reversed()
    }

    private func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var currentEnglish = ""
        var currentEnglishStart: String.Index?

        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char.isASCII && (char.isLetter || char.isNumber) {
                if currentEnglishStart == nil {
                    currentEnglishStart = index
                }
                currentEnglish.append(char)
            } else {
                if !currentEnglish.isEmpty {
                    let start = currentEnglishStart ?? index
                    tokens.append(Token(text: currentEnglish, range: start..<index))
                    currentEnglish = ""
                    currentEnglishStart = nil
                }
                if !char.isWhitespace {
                    let nextIndex = text.index(after: index)
                    tokens.append(Token(text: String(char), range: index..<nextIndex))
                }
            }
            index = text.index(after: index)
        }
        if !currentEnglish.isEmpty {
            let start = currentEnglishStart ?? text.endIndex
            tokens.append(Token(text: currentEnglish, range: start..<text.endIndex))
        }

        return tokens
    }

    private func segmentText(from tokens: [Token], in source: String) -> String {
        guard let first = tokens.first, let last = tokens.last else { return "" }
        return String(source[first.range.lowerBound..<last.range.upperBound])
    }

    private func isPurelyPunctuation(_ text: String) -> Bool {
        let cjkPunc: Set<Character> = [
            "，", "。", "！", "？", "、", "；", "：",
            "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",  // ""''
            "…", "—", "·"
        ]
        return text.allSatisfy { char in
            char.isPunctuation || char.isSymbol || char.isWhitespace || cjkPunc.contains(char)
        }
    }

    private func isPurelyDigits(_ text: String) -> Bool {
        text.allSatisfy { $0.isNumber || $0.isWhitespace || ",.，。".contains($0) }
    }

    private func isSentenceLike(_ text: String) -> Bool {
        if text.contains(where: { "。！？!?；;\n\r".contains($0) }) {
            return true
        }

        let commaCount = text.reduce(into: 0) { count, char in
            if "，,、：:".contains(char) {
                count += 1
            }
        }
        return commaCount >= 2
    }

    private func isSingleASCIIAlphaNumeric(_ text: String) -> Bool {
        guard text.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
    }

    /// 是否是单个 CJK 汉字（统一表意文字主区 / 扩展A / 兼容区）
    private func isSingleCJKCharacter(_ text: String) -> Bool {
        guard text.count == 1, let scalar = text.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0xF900...0xFAFF).contains(v)
    }

    private func finalizeIfIdle() {
        guard let pendingEditedAt = pendingEditedAt,
              Date().timeIntervalSince(pendingEditedAt) >= idleFinalizeDelay else {
            return
        }

        finalizePendingCorrections(reason: "idle")
        debugLog?("AutoLearn: 修改已稳定，停止监控")
        stopMonitoring()
    }

    private func finalizePendingCorrections(reason: String) {
        guard let delivered = deliveredText,
              let pendingEditedSegment = pendingEditedSegment else {
            return
        }

        let trimmedPending = pendingEditedSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPending.isEmpty else {
            debugLog?("AutoLearn: finalize skipped: pending is empty")
            return
        }
        guard trimmedPending != delivered.trimmingCharacters(in: .whitespacesAndNewlines) else {
            debugLog?("AutoLearn: finalize skipped: no change detected")
            return
        }
        guard pendingEditedSegment != lastLearnedSegment else {
            debugLog?("AutoLearn: finalize skipped: already learned this segment")
            return
        }

        // 先看最后一版；判不出来再往前找刚改完时的干净版本（跳过正在打拼音的中间状态）
        var candidates = [pendingEditedSegment]
        for snapshot in editedSnapshots.reversed() where !candidates.contains(snapshot) && snapshot != delivered {
            if VocabularyLearning.looksLikeComposition(snapshot, delivered: delivered, final: pendingEditedSegment) { continue }
            candidates.append(snapshot)
        }
        if config.bool(forKey: "autolearn_debug_text", defaultValue: false) {
            // 诊断开关（默认关，只在开发机上临时打开）：记下原文和每一版，用来查输入框里多出了什么
            debugLog?("AutoLearn[debug] 原文: \(delivered)")
            for (i, c) in candidates.enumerated() { debugLog?("AutoLearn[debug] 候选\(i): \(c)") }
            for (i, c) in editedSnapshots.enumerated() { debugLog?("AutoLearn[debug] 第\(i)版: \(c)") }
        }
        var chosen: (text: String, corrections: [LearnedTermCorrection])?
        for (i, candidate) in candidates.enumerated() {
            // 先不卡读音、把所有短替换都提出来，再逐条判断：读音相近，或改的是人名 / 地名 / 机构名 / 英文词，才学
            // （「李俊梅 → 吕俊梅」读音规则判不像，但显然是在改名字，见 VocabularyLearning.shouldLearn）
            let found = extractCorrections(original: delivered, edited: candidate, requireSoundAlike: false)
                .filter { VocabularyLearning.shouldLearn(variant: $0.variant, target: $0.target, in: candidate) }
            let learnable = found.filter { VocabularyLearning.isLearnableWord(VocabularyLearning.expandToWord($0.target, in: candidate)) }
            if !learnable.isEmpty {
                if i > 0 { debugLog?("AutoLearn: 最后一版判不出来，改用第 \(i) 个较早版本（输入框改完后多出了内容）") }
                chosen = (candidate, learnable)
                break
            }
        }
        guard let chosen else {
            debugLog?("AutoLearn: finalize(\(reason)): diff found no learnable corrections, beforeChars=\(delivered.count), afterChars=\(pendingEditedSegment.count), 版本数=\(candidates.count)")
            return
        }

        debugLog?("AutoLearn: 定稿后学习(\(reason)): count=\(chosen.corrections.count)")
        let added = learnWords(chosen.corrections.map(\.target), in: chosen.text, reason: reason)
        lastLearnedSegment = pendingEditedSegment

        // 改一次就学（2026-09-23 起）：新加进词库的词马上弹「已加入词库 · 撤销」
        if !added.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.onLearned?(added) }
        }
    }

    private func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    private func loadStoredCorrections(from json: [String: Any]) -> [StoredTermCorrection] {
        guard let rawEntries = json["term_corrections"] as? [[String: Any]] else {
            return []
        }

        return rawEntries.compactMap { item in
            guard let target = (item["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty else {
                return nil
            }

            let variants = item["variants"] as? [String] ?? []
            let cleanedVariants = variants
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.caseInsensitiveCompare(target) != .orderedSame }

            let category = (item["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return StoredTermCorrection(
                target: target,
                variants: cleanedVariants,
                category: category.isEmpty ? "其他" : category,
                source: item["source"] as? String ?? ""
            )
        }
    }

    private func hasVariantConflict(_ variant: String, target: String, in entries: [StoredTermCorrection]) -> Bool {
        let variantKey = variant.lowercased()
        let targetKey = target.lowercased()
        return entries.contains { entry in
            guard entry.target.lowercased() != targetKey else { return false }
            if entry.target.lowercased() == variantKey {
                return true
            }
            return entry.variants.contains(where: { $0.lowercased() == variantKey })
        }
    }

    private func hasExactCorrection(_ correction: LearnedTermCorrection, in entries: [StoredTermCorrection]) -> Bool {
        let targetKey = correction.target.lowercased()
        let variantKey = correction.variant.lowercased()
        return entries.contains { entry in
            guard entry.target.lowercased() == targetKey else { return false }
            return entry.variants.contains(where: { $0.lowercased() == variantKey })
        }
    }

    /// 读候选：丢掉过期的和不像听错的（旧版攒下的候选里约八成是改内容）；没有日期的旧候选从今天起算
    private func loadPendingCorrections(from json: [String: Any]) -> [PendingLearnedCorrection] {
        guard let rawEntries = json[pendingCorrectionsConfigKey] as? [[String: Any]] else {
            return []
        }
        let today = Self.dayString(Date())
        let oldest = Self.dayString(Date().addingTimeInterval(-Double(candidateLifetimeDays) * 86400))

        return rawEntries.compactMap { item in
            guard let target = (item["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty,
                  let variant = (item["variant"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !variant.isEmpty,
                  let count = item["count"] as? Int,
                  count > 0 else {
                return nil
            }
            let lastSeen = item["last_seen"] as? String ?? today
            guard lastSeen >= oldest, MishearingCheck.isLikelyMishearing(old: variant, new: target) else { return nil }
            return PendingLearnedCorrection(target: target, variant: variant, count: count, lastSeen: lastSeen)
        }
    }

    /// 启动时整理一次候选（过期、不像听错的直接清掉），有变化才写回
    func pruneLearningCandidates() {
        let json = config.loadConfig()
        guard let raw = json[pendingCorrectionsConfigKey] as? [[String: Any]] else { return }
        let kept = loadPendingCorrections(from: json)
        let hadUndated = raw.contains { $0["last_seen"] == nil }
        guard kept.count != raw.count || hadUndated else { return }
        config.save(values: [pendingCorrectionsConfigKey: kept.map(Self.candidateDictionary)])
        debugLog?("AutoLearn: 整理纠错候选 \(raw.count) → \(kept.count) 条")
    }

    private static func candidateDictionary(_ entry: PendingLearnedCorrection) -> [String: Any] {
        ["target": entry.target, "variant": entry.variant, "count": entry.count, "last_seen": entry.lastSeen]
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func saveCorrections(_ corrections: [LearnedTermCorrection], requireConfirmation: Bool = true) -> PersistedCorrections {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: config.configFileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        return persistCorrections(corrections, into: &json, requireConfirmation: requireConfirmation)
    }

    private func persistCorrections(_ corrections: [LearnedTermCorrection], into json: inout [String: Any], requireConfirmation: Bool) -> PersistedCorrections {
        var entries = loadStoredCorrections(from: json)
        var candidates = loadPendingCorrections(from: json)
        var added: [String] = []
        var pending: [String] = []
        var pendingSuggestions: [String] = []
        var skippedConflicts: [String] = []
        var didChange = false

        for correction in corrections {
            guard correction.target.caseInsensitiveCompare(correction.variant) != .orderedSame else { continue }
            if hasExactCorrection(correction, in: entries) {
                if let candidateIndex = candidates.firstIndex(where: {
                    $0.target.caseInsensitiveCompare(correction.target) == .orderedSame &&
                    $0.variant.caseInsensitiveCompare(correction.variant) == .orderedSame
                }) {
                    candidates.remove(at: candidateIndex)
                    didChange = true
                }
                continue
            }
            if hasVariantConflict(correction.variant, target: correction.target, in: entries) {
                skippedConflicts.append("\(correction.variant) -> \(correction.target)")
                continue
            }

            if requireConfirmation {
                let candidateIndex = candidates.firstIndex(where: {
                    $0.target.caseInsensitiveCompare(correction.target) == .orderedSame &&
                    $0.variant.caseInsensitiveCompare(correction.variant) == .orderedSame
                })

                if let candidateIndex {
                    candidates[candidateIndex].count += 1
                    candidates[candidateIndex].lastSeen = Self.dayString(Date())
                } else {
                    candidates.append(PendingLearnedCorrection(target: correction.target, variant: correction.variant,
                                                               count: 1, lastSeen: Self.dayString(Date())))
                }
                didChange = true

                let resolvedIndex = candidateIndex ?? (candidates.count - 1)
                let resolvedCandidate = candidates[resolvedIndex]

                if resolvedCandidate.count < requiredLearnCount {
                    pending.append("\(resolvedCandidate.variant) -> \(resolvedCandidate.target) (\(resolvedCandidate.count)/\(requiredLearnCount))")
                    pendingSuggestions.append("\(resolvedCandidate.variant) -> \(resolvedCandidate.target)")
                    continue
                }
            }

            if let existingIndex = entries.firstIndex(where: { $0.target.caseInsensitiveCompare(correction.target) == .orderedSame }) {
                let existingVariantsLower = Set(entries[existingIndex].variants.map { $0.lowercased() })
                if !existingVariantsLower.contains(correction.variant.lowercased()) {
                    entries[existingIndex].variants.append(correction.variant)
                    added.append("\(correction.variant) -> \(entries[existingIndex].target)")
                    didChange = true
                }
            } else {
                entries.append(StoredTermCorrection(target: correction.target, variants: [correction.variant], category: "其他", source: "auto"))
                added.append("\(correction.variant) -> \(correction.target)")
                didChange = true
            }

            if let promotedCandidateIndex = candidates.firstIndex(where: {
                   $0.target.caseInsensitiveCompare(correction.target) == .orderedSame &&
                   $0.variant.caseInsensitiveCompare(correction.variant) == .orderedSame
               }) {
                candidates.remove(at: promotedCandidateIndex)
                didChange = true
            }
        }

        if !skippedConflicts.isEmpty {
            debugLog?("AutoLearn: 跳过冲突术语纠正: count=\(skippedConflicts.count)")
        }

        if !pending.isEmpty {
            debugLog?("AutoLearn: 已记录术语候选，待再次确认: count=\(pending.count)")
        }

        guard didChange else { return PersistedCorrections(added: [], pending: []) }

        json["term_corrections"] = entries.map { entry in
            [
                "target": entry.target,
                "variants": entry.variants,
                "category": entry.category,
                "source": entry.source
            ]
        }
        json[pendingCorrectionsConfigKey] = candidates.map(Self.candidateDictionary)

        config.save(values: [
            "term_corrections": json["term_corrections"] ?? [],
            pendingCorrectionsConfigKey: json[pendingCorrectionsConfigKey] ?? []
        ])
        NotificationCenter.default.post(name: .voicePolishTermCorrectionsDidChange, object: nil)

        if !added.isEmpty {
            debugLog?("AutoLearn: 已自动添加术语纠正: count=\(added.count)")
        }
        return PersistedCorrections(
            added: added.map { $0.replacingOccurrences(of: " -> ", with: " → ") },
            pending: pendingSuggestions.map { $0.replacingOccurrences(of: " -> ", with: " → ") }
        )
    }

    // MARK: - Accessibility

    private func getFocusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return nil
        }
        let app = focusedApp as! AXUIElement
        // 对方 App 卡住时别拖住主线程（每 0.5 秒读一次）。只设在这个 App 的元素上——
        // 设在 system-wide 元素上会改掉整个进程的全局超时
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }

        let element = focusedElement as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.axTimeout)

        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let roleStr = role as? String {
            let textRoles = [kAXTextFieldRole, kAXTextAreaRole, "AXWebArea", "AXComboBox"]
            if textRoles.contains(where: { roleStr == ($0 as String) }) {
                return element
            }
        }

        var value: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           value is String {
            return element
        }

        return nil
    }

    private func getElementValue(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

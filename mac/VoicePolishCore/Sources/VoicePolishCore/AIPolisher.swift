import Foundation
import NaturalLanguage

public class AIPolisher {
    public enum HistoryRetention: String, CaseIterable {
        case forever
        case oneMonth
        case oneWeek
        case oneDay
        case off

        public static let configKey = "history_retention"
        public static let defaultValue: HistoryRetention = .forever

        public var title: String {
            switch self {
            case .forever: return "保存全部数据"
            case .oneMonth: return "保存一个月"
            case .oneWeek: return "保存一周"
            case .oneDay: return "保存 24 小时"
            case .off: return "不保存数据"
            }
        }

        public var detail: String {
            switch self {
            case .forever: return "不自动删除历史记录"
            case .oneMonth: return "自动删除 30 天前的记录"
            case .oneWeek: return "自动删除 7 天前的记录"
            case .oneDay: return "自动删除 24 小时前的记录"
            case .off: return "录音结束后不保留任何本地历史"
            }
        }

        fileprivate func cutoffDate(now: Date) -> Date? {
            switch self {
            case .forever:
                return nil
            case .oneMonth:
                return Calendar.current.date(byAdding: .day, value: -30, to: now)
            case .oneWeek:
                return Calendar.current.date(byAdding: .day, value: -7, to: now)
            case .oneDay:
                return Calendar.current.date(byAdding: .hour, value: -24, to: now)
            case .off:
                return .distantFuture  // 任何记录都视为过期 → 立即清除（含切到本项前的存量）
            }
        }
    }

    public struct TermCorrection {
        public let target: String
        public let variants: [String]
    }

    public struct PolishLog: Codable {
        public let time: String
        public let app: String
        public let asr: String
        public let output: String
        public let duration_ms: Int
        public let input_tokens: Int
        public let output_tokens: Int
        /// 新增：每条记录的稳定唯一标识。旧数据缺失则为 nil（用 stableIdentity 兜底）。
        public let id: String?
        /// 新增：关联音频文件名（相对 audio/ 目录，如 "<id>.m4a"）。无音频则 nil。
        public let audioFile: String?
        /// 记录类型：nil = 普通语音输入；"ask" = 长按问 AI（asr 存问题、output 存回答）
        public let kind: String?
        /// 问 AI 的话题 id：同一次对话里的多轮共用，历史页按它合并成一张卡
        public let thread: String?

        public init(time: String, app: String, asr: String, output: String, duration_ms: Int, input_tokens: Int, output_tokens: Int, id: String? = nil, audioFile: String? = nil, kind: String? = nil, thread: String? = nil) {
            self.time = time
            self.app = app
            self.asr = asr
            self.output = output
            self.duration_ms = duration_ms
            self.input_tokens = input_tokens
            self.output_tokens = output_tokens
            self.id = id
            self.audioFile = audioFile
            self.kind = kind
            self.thread = thread
        }

        public var isAsk: Bool { kind == "ask" }

        /// UI 用的稳定标识：新数据用 id；旧数据用关键字段哈希兜底（time 秒级精度不够）。
        public func stableIdentity(lineIndex: Int) -> String {
            if let id = id, !id.isEmpty { return id }
            return "legacy-\(lineIndex)-\(time)-\(asr.hashValue)-\(output.hashValue)"
        }
    }

    private static let defaultDoubaoPolishModel = "doubao-seed-2-0-pro-260215"
    private let apiURL = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!
    private let model = AIPolisher.defaultDoubaoPolishModel
    public var debugLog: ((String) -> Void)?
    public var polishLogAppNameProvider: (() -> String)?

    public init() {}

    public struct PolishSelection {
        public let provider: String
        public let model: String?

        public init(provider: String, model: String?) {
            self.provider = provider
            self.model = model
        }
    }

    public static func currentPolishSelection() -> PolishSelection {
        let config = VoicePolishConfig.shared
        let provider = config.string(forKey: "polish_provider") ?? "qwen"
        if isPolishDisabled(provider: provider) {
            return PolishSelection(provider: "none", model: nil)
        }
        switch provider {
        case "qwen":
            let saved = config.string(forKey: "qwen_polish_model")
            return PolishSelection(provider: "qwen", model: (saved?.isEmpty == false) ? saved! : "qwen3.6-flash")
        case "zhipu":
            return PolishSelection(provider: "zhipu", model: config.string(forKey: "zhipu_polish_model") ?? "glm-4.7-flash")
        default:
            let saved = config.string(forKey: "doubao_polish_model")
            return PolishSelection(provider: "doubao", model: (saved?.isEmpty == false) ? saved! : defaultDoubaoPolishModel)
        }
    }

    // MARK: - 术语纠正

    public func applyConfiguredTermCorrections(to text: String) -> String {
        Self.applyTermCorrections(configuredTermCorrections(), to: text)
    }

    /// 按词库把误写换成正写（2026-09-11 重写，旧版逐条整段替换会改坏正确的字）：
    /// - 已经是正写的地方不动：误写恰好是正写的一部分时（误写 APIK、正写 APIKey），原文里的 APIKey 不能变成 APIKeyey；
    /// - 英文/数字的误写要整词命中，前后不能紧挨英文字母或数字（SQL 不改 PostgreSQL 的尾巴）；
    /// - 中文误写若会把分词器切出的词拦腰截断（误写「徐向」遇到「徐向前」→ 徐/向前），不改；
    /// - 单遍替换：所有命中都在原文上找，长的误写优先、互不重叠，换进去的正写不会再被别的规则改一遍。
    static func applyTermCorrections(_ corrections: [TermCorrection], to text: String) -> String {
        let pairs = corrections
            .flatMap { correction in correction.variants.map { (variant: $0, target: correction.target) } }
            .filter { !$0.variant.isEmpty && $0.variant != $0.target }
            .sorted { $0.variant.count > $1.variant.count }
        guard !pairs.isEmpty, !text.isEmpty else { return text }

        let source = text as NSString
        lazy var cjkWordRanges = chineseWordRanges(in: text)
        var accepted: [(range: NSRange, target: String)] = []
        for pair in pairs {
            // 只差大小写的规则（chatgpt → ChatGPT）只改写法不对的地方；其余规则避开原文里已是正写的位置
            let caseOnly = pair.variant.caseInsensitiveCompare(pair.target) == .orderedSame
            let correctSpots = caseOnly ? [] : occurrences(of: pair.target, in: source)
            for range in occurrences(of: pair.variant, in: source) {
                guard isWholeLatinWord(range, variant: pair.variant, in: source) else { continue }
                if containsCJK(pair.variant), splitsWord(range, wordRanges: cjkWordRanges) { continue }
                if caseOnly, source.substring(with: range) == pair.target { continue }
                if correctSpots.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
                if accepted.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { continue }
                accepted.append((range, pair.target))
            }
        }
        guard !accepted.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for match in accepted.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: match.range, with: match.target)
        }
        return result as String
    }

    /// 不分大小写地找出 needle 在 text 里的所有（不重叠）位置
    private static func occurrences(of needle: String, in text: NSString) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var location = 0
        while location < text.length {
            let found = text.range(of: needle, options: .caseInsensitive,
                                   range: NSRange(location: location, length: text.length - location))
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            location = found.location + found.length
        }
        return ranges
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    /// 分词器切出的多字词（NSRange）。只用来判断命中有没有把某个词切断。
    private static func chineseWordRanges(in text: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let r = NSRange(tokenRange, in: text)
            if r.length > 1 { ranges.append(r) }
            return true
        }
        return ranges
    }

    /// 命中和某个多字词部分重叠（词的一部分在命中外面）→ 替换会把这个词改坏
    private static func splitsWord(_ range: NSRange, wordRanges: [NSRange]) -> Bool {
        wordRanges.contains { word in
            let overlap = NSIntersectionRange(word, range).length
            return overlap > 0 && overlap < word.length
        }
    }

    /// 以英文字母/数字开头（结尾）的误写，前（后）一个字符不能也是英文字母/数字，否则是命中了长单词的一部分
    private static func isWholeLatinWord(_ range: NSRange, variant: String, in text: NSString) -> Bool {
        func isLatinAlphanumeric(_ c: unichar) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
        }
        let v = variant as NSString
        if isLatinAlphanumeric(v.character(at: 0)), range.location > 0,
           isLatinAlphanumeric(text.character(at: range.location - 1)) {
            return false
        }
        let end = range.location + range.length
        if isLatinAlphanumeric(v.character(at: v.length - 1)), end < text.length,
           isLatinAlphanumeric(text.character(at: end)) {
            return false
        }
        return true
    }

    public func meaningfulCharacterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { partialResult, scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return partialResult }
            if CharacterSet.punctuationCharacters.contains(scalar) { return partialResult }
            if CharacterSet.symbols.contains(scalar) { return partialResult }
            return partialResult + 1
        }
    }

    private func configuredTermCorrections() -> [TermCorrection] {
        guard let data = try? Data(contentsOf: VoicePolishConfig.shared.configFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["term_corrections"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let target = (item["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty else {
                return nil
            }

            let variants = item["variants"] as? [String] ?? []
            let cleanedVariants = variants
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != target }

            return TermCorrection(target: target, variants: cleanedVariants)
        }
    }

    private func configuredPersonalVocabulary() -> [String] {
        guard let data = try? Data(contentsOf: VoicePolishConfig.shared.configFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var words: [String] = []
        if let entries = json["term_corrections"] as? [[String: Any]] {
            words.append(contentsOf: entries.compactMap { entry in
                if let enabled = entry["enabled"] as? Bool, !enabled {
                    return nil
                }
                guard let target = (entry["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !target.isEmpty else {
                    return nil
                }
                return target
            })
        }

        if let hotWords = json["hot_words"] as? [String] {
            words.append(contentsOf: hotWords.compactMap { rawWord in
                let word = rawWord
                    .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return word?.isEmpty == false ? word : nil
            })
        }

        var seen = Set<String>()
        return words.filter { word in
            let key = word.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func personalVocabularyPrompt() -> String {
        let words = configuredPersonalVocabulary()
        guard !words.isEmpty else { return "" }

        let limitedWords = words.prefix(80).joined(separator: "、")
        return """

        ## 用户个人词库
        以下是用户常说的人名、产品名、项目名或专有表达。整理文本时要优先保留这些准确写法；当语音转写里出现读音相近、大小写不同或空格不同的表达时，可以修正为词库中的写法，但不要凭空加入用户没有表达过的词：\(limitedWords)
        """
    }

    /// 完整润色 system prompt：基础规则 + 个人词库 + 风格画像（都是有内容才附加）。
    /// 词库让模型别"纠正"用户的专有写法；画像让整理结果贴合用户的说话习惯（越用越懂你）——
    /// 画像分两层：人身特征全局注入，场合特征按当前前台 App 的场景注入（聊天≠文档≠代码）。
    ///
    /// 画像观察期（owner 2026-07-03 定）：画像照常统计、照常写 style_profile.json，
    /// 但注入默认关闭——先观察它总结得准不准，确认后把下面的开关置 true 再生效，
    /// 避免总结错了反而把润色带偏。
    private func composedPolishSystemPrompt(outputLanguage: OutputLanguage? = nil) -> String {
        var prompt = cloudASRPolishPrompt
        if let outputLanguage { prompt += Self.outputLanguageSystemSection(for: outputLanguage) }
        // 基线对齐（owner 2026-07-03 实测定）：润色提示词严格回到线上 2.5.1 的组成。
        // 实测发现叠加"保留/不要改"类条款会让模型整体变怂（废话不删、语序不理、口误不修），
        // 所以词库段和画像段都默认不注入，之后一次只开一个、用真实用例验证再放行。
        if VoicePolishConfig.shared.bool(forKey: "polish_vocab_injection_enabled", defaultValue: false) {
            prompt += personalVocabularyPrompt()
        }
        if VoicePolishConfig.shared.bool(forKey: "style_profile_injection_enabled", defaultValue: false),
           let styleSection = StyleProfileStore.promptSection(forAppName: polishLogAppNameProvider?()) {
            prompt += "\n\n" + styleSection
        }
        return prompt
    }

    // MARK: - 云端 ASR 后润色

    private let cloudASRPolishPrompt = """
    你是一个语音转文字的整理助手。用户通过语音输入了一段话，你要把它整理成好读的文本。

    ## 你的角色
    想象你是用户的表达优化师，用户口述了一段想法，你帮他整理成用户看到结果时应该觉得"这就是我想说的，只是整理得更清楚、便于阅读和理解"。

    ## 可以做的事
    - 分段：根据语义、语境分段，避免大段文字堆积，让阅读体验更好。
    - 标点：修正标点符号，让断句更自然。适当使用冒号、分号来连接关联内容
    - 列表：当你觉得用户表达的语义里包含或者就是并列内容时，或用户说“第一、第二、第三”“一个是、另一个是、最后”，或者明显是在口述步骤/清单/多个独立条目时，你要把其中适合并列的列编号显示。
    - 去除口语冗余：删掉重复的词、无意义的语气词（"就是"、"然后"、"嗯"等）
    - 理顺断句：口语中断裂或不通顺的句子，可以根据语义、语境适当的轻微调整语序使其通顺
    - 数字：口语中的汉字数字转为阿拉伯数字（"两到三次"→"2 到 3 次"，"大概五百块"→"大概 500 块"），但成语、固定搭配除外（"一模一样"、"三心二意"不转）
    - 明显重复的短语、绕口表达要合并整理，但不要改变用户原意。
    - “保留用户用词”不等于原样保留口语里的重复结构。对于明显重复、断裂、不顺的表达，要做轻微合并和理顺。
    - 如果一句话本身已经通顺，可以少改；但如果存在明显重复、语序绕、主语不清，要主动整理到自然可读。

    ## 不能做的事
    - 不要回答或回应用户说的内容——你不是对话助手，你是用户的表达转写整理工具。即使用户说的是一个问题，也不要给出答案或建议
    - 同义词不替换："不如"不要改成"不妨"，"想要的效果不一样"不要改成"需求各异"
    - 不要把口语改成书面语：保留用户自己的说话风格
    - 不要添加用户没说过的内容，包括总结句、过渡句、小标题
    - 不要使用加粗、标题等富文本格式
    - 不要随意更换用户的用词，除非用户用词逻辑不恰当
    - 不要翻译用户输入的语言种类

    ## 输出格式
    纯文本，适当分段。并列内容用编号列表。不要加粗、不要加标题。
    """

    /// 用户是否选择了"不优化"（polish_provider == "none"）。
    public static func isPolishDisabled(provider: String?) -> Bool {
        provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none"
    }

    public func isPolishEnabled() -> Bool {
        !Self.isPolishDisabled(provider: VoicePolishConfig.shared.string(forKey: "polish_provider"))
    }

    /// 用户要求本次用某种语言输出时附在待整理文本后面的标记；system prompt 里的「目标语言」一节解释它。
    static func outputRequestMarker(for language: OutputLanguage) -> String { "【本次要求：用\(language.name)输出】" }

    static func outputLanguageSystemSection(for language: OutputLanguage) -> String {
        """


        ## 目标语言
        如果待整理文本后面带有\(outputRequestMarker(for: language))，说明用户要求这段话用\(language.name)输出：先按上面的规则整理，再把整理结果翻译成自然、地道的\(language.name)，只输出\(language.name)译文；人名、产品名、专有名词保留原样；不要输出其他语言，不要加任何说明或翻译标注。如果整理后的文本本来就是\(language.name)，直接输出整理结果。此时「不要翻译用户输入的语言种类」这条不适用。
        """
    }

    static func makeCloudASRPolishUserPrompt(for text: String, outputLanguage: OutputLanguage? = nil) -> String {
        if let outputLanguage {
            return """
            待整理文本：
            \(text)

            \(outputRequestMarker(for: outputLanguage))
            """
        }
        if shouldUseLanguagePreservingPrompt(for: text) {
            return """
            Keep the original language. Do not translate. Preserve Chinese and English as they appear. Polish this speech transcript only:
            \(text)
            """
        }

        return """
        待整理文本：
        \(text)
        """
    }

    private static func shouldUseLanguagePreservingPrompt(for text: String) -> Bool {
        var latinLetters = 0
        var cjkCharacters = 0
        var englishWords = 0
        var currentEnglishWordLength = 0

        func finishEnglishWord() {
            if currentEnglishWordLength >= 2 {
                englishWords += 1
            }
            currentEnglishWordLength = 0
        }

        for scalar in text.unicodeScalars {
            if isASCIILetter(scalar) {
                latinLetters += 1
                currentEnglishWordLength += 1
            } else {
                finishEnglishWord()
                if isCJKCharacter(scalar) {
                    cjkCharacters += 1
                }
            }
        }
        finishEnglishWord()

        let hasEnglishSentence = englishWords >= 3 || latinLetters >= max(8, cjkCharacters)
        let hasMixedChineseEnglish = cjkCharacters > 0 && englishWords >= 2
        return hasEnglishSentence || hasMixedChineseEnglish
    }

    private static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func isCJKCharacter(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value))
    }

    private func polishProvider() -> (name: String, url: URL, model: String, apiKey: String)? {
        let config = VoicePolishConfig.shared
        let provider = config.string(forKey: "polish_provider") ?? "qwen"

        switch provider {
        case "qwen":
            guard let key = config.string(forKey: "dashscope_api_key", envKey: "DASHSCOPE_API_KEY"),
                  !key.isEmpty else { return nil }
            let saved = config.string(forKey: "qwen_polish_model")
            // 未选过 → 自动选择（质量优先 + 额度用完自动降级）；老用户手动选过的值原样保留。
            let model = (saved?.isEmpty == false) ? saved! : PolishModelRouter.autoValue
            let url = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
            return ("qwen", url, model, key)
        case "zhipu":
            guard let key = config.string(forKey: "zhipu_api_key", envKey: "ZHIPU_API_KEY"),
                  !key.isEmpty else { return nil }
            let model = config.string(forKey: "zhipu_polish_model") ?? "glm-4.7-flash"
            let url = URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")!
            return ("zhipu", url, model, key)
        default:
            guard let key = getAPIKey() else { return nil }
            let saved = config.string(forKey: "doubao_polish_model")
            let doubaoModel = (saved?.isEmpty == false) ? saved! : model
            return ("doubao", apiURL, doubaoModel, key)
        }
    }

    /// outputLanguage：用户用语音口令要求的目标语言（nil = 照常保留原语言）
    public func polishCloudASROutput(text: String, outputLanguage: OutputLanguage? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        // 会员选了「优先走会员服务」：填了自己的 Key 也走会员通道（用户没选「不优化」时）
        if HostedRoute.current(ownKeyConfigured: polishProvider() != nil) == .member,
           !Self.isPolishDisabled(provider: VoicePolishConfig.shared.string(forKey: "polish_provider")) {
            polishHosted(route: .member, text: text, outputLanguage: outputLanguage, completion: completion)
            return
        }
        guard let provider = polishProvider() else {
            // 没配自己的 key：试用用户走服务器代理润色（千问，owner 出 API 费）。
            // 用户主动选了"不优化"(none) 则尊重；已激活(买断)用户绝不走试用。
            let providerSetting = VoicePolishConfig.shared.string(forKey: "polish_provider")
            let hostedRoute = HostedRoute.current(ownKeyConfigured: false)
            if !Self.isPolishDisabled(provider: providerSetting) && hostedRoute != .none {
                polishHosted(route: hostedRoute, text: text, outputLanguage: outputLanguage, completion: completion)
                return
            }
            completion(.failure(PolishError.noAPIKey))
            return
        }

        debugLog?("Cloud ASR polish provider=\(provider.name) model=\(provider.model)")

        let systemPrompt = composedPolishSystemPrompt(outputLanguage: outputLanguage)
        let userPrompt = Self.makeCloudASRPolishUserPrompt(for: text, outputLanguage: outputLanguage)

        func makeBody(_ model: String) -> [String: Any] {
            var body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ]
            ]
            if provider.name == "qwen" {
                body["top_p"] = 0.8
                body["temperature"] = 0.7
                body["result_format"] = "message"
                body["enable_thinking"] = false
            } else if provider.name == "zhipu" {
                body["temperature"] = 0.1
                body["max_tokens"] = 2000
                body["thinking"] = ["type": "disabled"]
            } else {  // doubao
                body["temperature"] = 0.1
                body["max_tokens"] = 2000
                body["thinking"] = ["type": "disabled"]  // 关闭深度思考：润色不需要，且更快
            }
            return body
        }

        let finish: (Result<(String, Int, Int), Error>) -> Void = { result in
            switch result {
            case .success(let (content, _, _)):
                // 自带 key（直连）润色成功 → 累计用量，等握手上报（仅数字、不含内容）；代理润色由服务器记账。
                if !content.isEmpty { TrialManager.shared.recordSelfKeyUsage(chars: content.count) }
                completion(.success(content))
            case .failure(let error):
                completion(.failure(error))
            }
        }

        if provider.name == "qwen" {
            // 自动选择 → 对应候选队列（质量优先/速度优先）；手动选择 → 单模型（403 也会被标记，供设置页提示）。
            let candidates = PolishModelRouter.isAuto(provider.model)
                ? PolishModelRouter.candidates(for: provider.model)
                : [provider.model]
            attemptQwenPolish(candidates: candidates, url: provider.url, apiKey: provider.apiKey,
                              makeBody: makeBody, completion: finish)
        } else {
            callChatCompletionsWithTokens(url: provider.url, apiKey: provider.apiKey,
                                          body: makeBody(provider.model), completion: finish)
        }
    }

    /// 按候选顺序尝试润色：403 额度类失败 → 标记该模型并换下一个；其余错误原样返回。
    /// 只在收到明确的 403 时降级——网络断线等传输错误不换模型，避免串行多次超时。
    private func attemptQwenPolish(candidates: [String], url: URL, apiKey: String,
                                   makeBody: @escaping (String) -> [String: Any],
                                   completion: @escaping (Result<(String, Int, Int), Error>) -> Void) {
        guard let model = candidates.first else {
            completion(.failure(PolishError.apiError("润色模型均不可用（额度用完）")))
            return
        }
        debugLog?("Cloud ASR polish qwen attempt model=\(model)")
        callChatCompletionsWithTokens(url: url, apiKey: apiKey, body: makeBody(model)) { [weak self] result in
            if case .failure(let err) = result, case PolishError.quotaExhausted = err {
                PolishModelRouter.markExhausted(model)
                let rest = Array(candidates.dropFirst())
                if let self = self, let next = rest.first {
                    self.debugLog?("Cloud ASR polish qwen: \(model) 额度类失败(403)，自动降级到 \(next)")
                    self.attemptQwenPolish(candidates: rest, url: url, apiKey: apiKey,
                                           makeBody: makeBody, completion: completion)
                    return
                }
            }
            completion(result)
        }
    }

    // MARK: - 试用代理润色（POST /trial/polish，owner 出 API 费）

    /// 走服务器试用代理润色（POST /trial/polish）。固定用 qwen3.8-max——质量优先链的头部：
    /// 试用是转化窗口给最好的效果（2026-08-06 实测 3.7-plus 会编造整句、3.8-max 最稳还更快，
    /// 成本有服务器三层限额兜底）。故意不跟随用户的「润色设置」——那是 BYOK 用户用的。
    private func polishHosted(route: HostedRoute, text: String, outputLanguage: OutputLanguage? = nil,
                              completion: @escaping (Result<String, Error>) -> Void) {
        // 试用：qwen3.8-max（转化窗口给最好效果，2026-08-06 实测）；会员：qwen3.7-plus（与 owner 自用一致，会员成本按它测算）
        let model = route == .member ? "qwen3.7-plus" : "qwen3.8-max"
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": composedPolishSystemPrompt(outputLanguage: outputLanguage)],
                ["role": "user", "content": Self.makeCloudASRPolishUserPrompt(for: text, outputLanguage: outputLanguage)]
            ],
            "top_p": 0.8,
            "temperature": 0.7,
            "result_format": "message",
            "enable_thinking": false
        ]
        debugLog?("Cloud ASR polish: \(route == .member ? "MEMBER" : "TRIAL") via proxy, model=\(model)")
        let log = debugLog
        TrialManager.shared.hostedPost(route: route, endpoint: "polish", jsonBody: body) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            let status = response?.statusCode ?? 0
            if status == 200,
               let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
                return
            }
            // 非 200：试用层错误（含 429 润色额度用尽）。把真实原因带回上层，用于提醒用户。
            let errJson = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            let expired = (errJson?["code"] as? String) == "trial_expired" || (errJson?["expired"] as? Bool) == true
            let msg = expired ? "试用已结束 · 开通会员，或填自己的 Key"
                : Self.extractAPIErrorMessage(from: errJson) ?? (route == .member ? "会员润色失败（\(status)）" : "试用润色失败（\(status)）")
            log?("Hosted polish failed: \(msg)")
            completion(.failure(PolishError.apiError(msg)))
        }
    }

    // MARK: - HTTP 调用

    private func callChatCompletionsWithTokens(url: URL, apiKey: String, body: [String: Any], completion: @escaping (Result<(String, Int, Int), Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(PolishError.noData))
                return
            }

            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let json = json,
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    let usage = json["usage"] as? [String: Any]
                    let inputTokens = usage?["prompt_tokens"] as? Int ?? 0
                    let outputTokens = usage?["completion_tokens"] as? Int ?? 0
                    completion(.success((content.trimmingCharacters(in: .whitespacesAndNewlines), inputTokens, outputTokens)))
                } else if let apiMessage = Self.extractAPIErrorMessage(from: json) {
                    // 服务端业务错误：把真实原因带出去，别再吞成 parseError。
                    // 403 单独标为额度类失败（免费额度用完即停/欠费），自动路由靠它降级换模型。
                    if (response as? HTTPURLResponse)?.statusCode == 403 {
                        completion(.failure(PolishError.quotaExhausted(apiMessage)))
                    } else {
                        completion(.failure(PolishError.apiError(apiMessage)))
                    }
                } else {
                    completion(.failure(PolishError.parseError))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func getAPIKey() -> String? {
        // 统一走 VoicePolishConfig：secret 路由到 Keychain（env 命中后经 saveSecret 持久化）。
        // 旧版遗留的 Keychain item 由 reconcileSecrets / migrateLegacyArkKeychainItem 迁移，此处不再回写明文。
        VoicePolishConfig.shared.string(forKey: "ark_api_key", envKey: "ARK_API_KEY", persistEnvValue: true)
    }

    // MARK: - 语音问答（长按问 AI）

    static let askSystemPrompt = """
    你是用户身边的语音问答助手。用户用语音提问，问题可能带口语、可能不完整。直接回答：先给结论，再展开要点；用用户提问的语言回答；不要客套，不要复述问题，结尾不要追问「要不要……」；不确定就说不确定。篇幅随问题而定：简单问题两三句说完，复杂问题可以分组展开，但不要注水。
    排版用轻量 Markdown（面板会渲染）：段落之间空一行，每段只说一件事；列举多项时逐条分行，用「1. 」或「- 」开头；内容分几组时用「### 组名」做小标题；每条里的关键词用 **加粗** 标出（一条最多一处）；不用表格、引用、代码块。
    """

    /// 模型没有时钟：每次提问都把「现在」写进提示词。不写的话它只能从搜到的网页里猜今天几号
    /// （网页常是前一两天发的，2026-09-11 实测 4 次全答成前一天），问「现在几点」也答不出。
    static func askTimeLine(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let week = ["日", "一", "二", "三", "四", "五", "六"][max(0, min(6, (c.weekday ?? 1) - 1))]
        let offset = timeZone.secondsFromGMT(for: now)
        let zone: String
        if offset == 8 * 3600 {
            zone = "北京时间"
        } else {
            let h = offset / 3600, m = abs(offset % 3600) / 60
            zone = m == 0 ? String(format: "UTC%+d", h) : String(format: "UTC%+d:%02d", h, m)
        }
        return "当前时间：\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日 星期\(week) "
            + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) + "（\(zone)）。"
    }

    /// 问题里带时效词（今天/最新/价格…）→ 联网时强制搜索。
    static func isTimeSensitive(_ question: String) -> Bool {
        let cues = ["今天", "现在", "目前", "最近", "最新", "新闻", "价格", "股价", "汇率", "天气", "几号", "星期",
                                 "多少钱", "发布", "更新", "今年", "本周", "这周", "昨天", "明天", "上市", "2025", "2026", "2027"]
        return cues.contains { question.contains($0) }
    }

    /// 用当前配置的润色模型回答一个问题（千问附带联网搜索；问题带时效词时强制搜）。
    /// history：本话题之前的问答对（多轮续聊时带上，最多 6 轮）。
    /// onPartial：流式输出，每收到一段就回调累计文本；没配 key 的试用用户走代理（不流式，只回调一次）。
    public func answer(question: String,
                       history: [(question: String, answer: String)] = [],
                       onPartial: ((String) -> Void)? = nil,
                       completion: @escaping (Result<String, Error>) -> Void) {
        var messages: [[String: Any]] = [["role": "system", "content": Self.askSystemPrompt + "\n" + Self.askTimeLine()]]
        for turn in history.suffix(6) {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": question])

        // 会员优先走会员：有自己的 Key 也走托管问答（与润色同一条规则）
        let ownProvider = polishProvider()
        let preferHosted = ownProvider != nil && HostedRoute.current(ownKeyConfigured: true) == .member
        guard let provider = ownProvider, !preferHosted else {
            let providerSetting = VoicePolishConfig.shared.string(forKey: "polish_provider")
            let hostedRoute = HostedRoute.current(ownKeyConfigured: ownProvider != nil)
            if !Self.isPolishDisabled(provider: providerSetting) && hostedRoute != .none {
                // 托管问答（试用/会员）一律 qwen3.7-plus，与 owner 自用一致（Ray 2026-09-12）；联网与强制搜索由服务器放行
                var body: [String: Any] = ["model": "qwen3.7-plus", "messages": messages, "top_p": 0.8, "temperature": 0.5,
                                           "result_format": "message", "enable_thinking": false, "enable_search": true]
                if Self.isTimeSensitive(question) { body["search_options"] = ["forced_search": true] }
                TrialManager.shared.hostedPost(route: hostedRoute, endpoint: "polish", jsonBody: body) { data, response, error in
                    if let error { completion(.failure(error)); return }
                    if let data, (response?.statusCode ?? 0) == 200,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String {
                        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        onPartial?(text)
                        completion(.success(text))
                    } else {
                        let errJson = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
                        completion(.failure(PolishError.apiError(Self.extractAPIErrorMessage(from: errJson) ?? "问答请求失败（\(response?.statusCode ?? 0)）")))
                    }
                }
                return
            }
            completion(.failure(PolishError.noAPIKey))
            return
        }
        // 千问联网默认由模型自己判断要不要搜，它觉得会答的就不搜、答案可能过期；
        // 问题里带时效词时强制搜，其他问题维持智能判断。
        // 搜索档位一律用默认，别指定 search_strategy="standard"：它只拿回默认档约一半的资料、结果偏旧
        // （2026-09-11 实测「美联储主席是谁」standard 档 3 次都答成已卸任的前任，默认档每次都对）。
        let forceSearch = Self.isTimeSensitive(question)
        debugLog?("Ask provider=\(provider.name) model=\(provider.model) forceSearch=\(forceSearch) history=\(history.count)")
        func makeBody(_ model: String, search: Bool) -> [String: Any] {
            var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
            if provider.name == "qwen" {
                body["top_p"] = 0.8; body["temperature"] = 0.5; body["enable_thinking"] = false
                if search {
                    body["enable_search"] = true
                    if forceSearch { body["search_options"] = ["forced_search": true] }
                }
            } else {
                body["temperature"] = 0.5; body["max_tokens"] = 1200; body["thinking"] = ["type": "disabled"]
            }
            return body
        }
        let candidates: [String] = provider.name == "qwen"
            ? (PolishModelRouter.isAuto(provider.model) ? PolishModelRouter.candidates(for: provider.model) : [provider.model])
            : [provider.model]
        func attempt(_ index: Int, search: Bool) {
            guard index < candidates.count else {
                completion(.failure(PolishError.apiError("问答模型均不可用（额度用完）")))
                return
            }
            let model = candidates[index]
            streamChat(url: provider.url, apiKey: provider.apiKey, body: makeBody(model, search: search), onPartial: onPartial) { [weak self] result in
                switch result {
                case .success(let text):
                    if !text.isEmpty { TrialManager.shared.recordSelfKeyUsage(chars: text.count) }
                    completion(.success(text))
                case .failure(let err):
                    if case PolishError.quotaExhausted = err {
                        PolishModelRouter.markExhausted(model)
                        self?.debugLog?("Ask: \(model) 额度类失败，降级到下一个")
                        attempt(index + 1, search: search)
                    } else if search, case PolishError.apiError = err {
                        self?.debugLog?("Ask with enable_search failed, retrying without: \(err)")
                        attempt(index, search: false)
                    } else {
                        completion(.failure(err))
                    }
                }
            }
        }
        attempt(0, search: provider.name == "qwen")
    }

    /// OpenAI 兼容的流式对话（SSE）：每收到一段增量就回调累计文本，结束时给完整文本。
    private func streamChat(url: URL, apiKey: String, body: [String: Any],
                            onPartial: ((String) -> Void)?,
                            completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 90
        do { request.httpBody = try JSONSerialization.data(withJSONObject: body) } catch { completion(.failure(error)); return }
        let reader = SSEReader(onPartial: onPartial, completion: completion)
        let session = URLSession(configuration: .default, delegate: reader, delegateQueue: nil)
        reader.session = session
        session.dataTask(with: request).resume()
    }

    /// 逐块解析 SSE，把 delta.content 累计起来；非 200 时把服务端错误原样带出（403 = 额度类）
    private final class SSEReader: NSObject, URLSessionDataDelegate {
        private let onPartial: ((String) -> Void)?
        private let completion: (Result<String, Error>) -> Void
        private var buffer = Data()
        private var accumulated = ""
        private var statusCode = 200
        private var errorBody = Data()
        private var finished = false
        var session: URLSession?

        init(onPartial: ((String) -> Void)?, completion: @escaping (Result<String, Error>) -> Void) {
            self.onPartial = onPartial
            self.completion = completion
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard statusCode == 200 else { errorBody.append(data); return }
            buffer.append(data)
            while let range = buffer.range(of: Data([0x0A])) {   // 按行切
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0...range.lowerBound)
                guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { continue }
                guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      let choice = (json["choices"] as? [[String: Any]])?.first else { continue }
                let piece = ((choice["delta"] as? [String: Any])?["content"] as? String)
                    ?? ((choice["message"] as? [String: Any])?["content"] as? String)
                if let piece, !piece.isEmpty {
                    accumulated += piece
                    let snapshot = accumulated
                    DispatchQueue.main.async { self.onPartial?(snapshot) }
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            defer { self.session?.finishTasksAndInvalidate() }
            guard !finished else { return }
            finished = true
            if let error { completion(.failure(error)); return }
            guard statusCode == 200 else {
                let json = try? JSONSerialization.jsonObject(with: errorBody) as? [String: Any]
                let message = AIPolisher.extractAPIErrorMessage(from: json) ?? "HTTP \(statusCode)"
                completion(.failure(statusCode == 403 ? PolishError.quotaExhausted(message) : PolishError.apiError(message)))
                return
            }
            let text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(text.isEmpty ? .failure(PolishError.parseError) : .success(text))
        }
    }

    // MARK: - 日志

    public func writePolishLog(asr: String, output: String, durationMs: Int, inputTokens: Int = 0, outputTokens: Int = 0, id: String? = nil, audioFile: String? = nil) {
        let entry = makePolishLogEntry(
            asr: asr,
            output: output,
            durationMs: durationMs,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            id: id ?? UUID().uuidString,
            audioFile: audioFile
        )

        // 写入本地记录文件（不外传）
        appendToPendingLog(entry)
    }

    /// 问 AI 的一轮问答写进历史（问题存 asr、回答存 output），同一话题共用 thread
    public func writeAskLog(question: String, answer: String, thread: String, durationMs: Int) {
        let entry = makePolishLogEntry(asr: question, output: answer, durationMs: durationMs, inputTokens: 0, outputTokens: 0,
                                       id: UUID().uuidString, audioFile: nil, kind: "ask", thread: thread)
        appendToPendingLog(entry)
    }

    func makePolishLogEntry(asr: String, output: String, durationMs: Int, inputTokens: Int, outputTokens: Int, id: String? = nil, audioFile: String? = nil, kind: String? = nil, thread: String? = nil) -> PolishLog {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return PolishLog(
            time: formatter.string(from: Date()),
            app: polishLogAppNameProvider?() ?? "键盘",
            asr: asr,
            output: output,
            duration_ms: durationMs,
            input_tokens: inputTokens,
            output_tokens: outputTokens,
            id: id,
            audioFile: audioFile,
            kind: kind,
            thread: thread
        )
    }

    public static func historyLogFileURL() -> URL? {
        #if os(macOS)
        return VoicePolishConfig.shared.configDirectoryURL.appendingPathComponent("polish_log.jsonl")
        #else
        return pendingLogFileURL()
        #endif
    }

    private static func pendingLogFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.voicepolish.shared")?
            .appendingPathComponent("polish_log_pending.jsonl")
    }

    private func appendToPendingLog(_ entry: PolishLog) {
        // 「不保存数据」：文字不落盘，连刚生成的音频也一并删掉，避免留下孤儿文件
        if Self.currentHistoryRetention() == .off {
            AudioClipStore.defaultStore().delete(fileName: entry.audioFile)
            return
        }

        guard let enc = HistoryCrypto.defaultEncryptor(),
              let encryptedLine = HistoryCrypto.encodeLine(entry, enc: enc),
              let lineData = (encryptedLine + "\n").data(using: .utf8) else {
            AudioClipStore.defaultStore().delete(fileName: entry.audioFile)
            NSLog("[history] encryption unavailable, skipping history record")
            return
        }

        guard let logFile = Self.historyLogFileURL() else { return }
        let audioStore = AudioClipStore.defaultStore()
        let retention = Self.currentHistoryRetention()

        // 追加 + 裁剪在同一把锁里：设置窗那边的整文件重写若插在中间，这条就丢了。
        HistoryFileLock.withLock {
            try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(lineData)
                    handle.closeFile()
                }
            } else {
                try? lineData.write(to: logFile)
            }

            Self.pruneLogFile(at: logFile, retention: retention, encryptor: enc) { removed in
                audioStore.delete(fileName: removed.audioFile)  // 裁剪过期记录时一并删音频
            }
        }
    }

    public static func currentHistoryRetention(config: VoicePolishConfig = .shared) -> HistoryRetention {
        guard let raw = config.string(forKey: HistoryRetention.configKey),
              let retention = HistoryRetention(rawValue: raw) else {
            return HistoryRetention.defaultValue
        }
        return retention
    }

    public static func shouldKeepPolishLog(_ log: PolishLog, retention: HistoryRetention, now: Date = Date()) -> Bool {
        guard let cutoff = retention.cutoffDate(now: now),
              let date = polishLogDate(from: log.time) else {
            return true
        }
        return date >= cutoff
    }

    @discardableResult
    public static func pruneLogFile(at fileURL: URL, retention: HistoryRetention, now: Date = Date(), encryptor: Encryptor? = nil, onRemove: ((PolishLog) -> Void)? = nil) -> Int {
        guard retention != .forever else { return 0 }

        return HistoryFileLock.withLock { () -> Int in
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }

            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            var keptLines: [String] = []
            var removedCount = 0

            for line in lines where !line.isEmpty {
                let rawLine = String(line)
                guard let log = HistoryCrypto.decodeLine(rawLine, enc: encryptor) else {
                    keptLines.append(rawLine)
                    continue
                }

                if shouldKeepPolishLog(log, retention: retention, now: now) {
                    keptLines.append(rawLine)
                } else {
                    removedCount += 1
                    onRemove?(log)  // 让调用方删掉该条对应的音频文件
                }
            }

            guard removedCount > 0 else { return 0 }

            let nextContent = keptLines.joined(separator: "\n")
                + (keptLines.isEmpty ? "" : "\n")
            try? nextContent.write(to: fileURL, atomically: true, encoding: .utf8)
            return removedCount
        }
    }

    private static func polishLogDate(from raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }

    public enum PolishError: LocalizedError {
        case noAPIKey
        case noData
        case parseError
        case apiError(String)   // 服务端返回的业务错误（鉴权/限流等），带真实原因
        case quotaExhausted(String)   // 403 额度类失败（免费额度用完即停/欠费），自动路由靠它降级

        public var errorDescription: String? {
            switch self {
            case .noAPIKey: return "未配置润色模型的 API key"
            case .noData: return "润色服务未返回数据"
            case .parseError: return "润色返回无法解析"
            case .apiError(let msg): return msg
            case .quotaExhausted(let msg): return msg
            }
        }
    }

    /// 从 OpenAI 兼容 / DashScope 的错误响应里取人话原因：
    /// 兼容 {"error":{"message":...}}、{"message":...,"code":...}、{"error":"..."}。
    static func extractAPIErrorMessage(from json: [String: Any]?) -> String? {
        guard let json = json else { return nil }
        if let err = json["error"] as? [String: Any] {
            let code = err["code"] as? String
            let type = err["type"] as? String
            let m = err["message"] as? String
            if let friendly = friendlyProviderError(code: code, type: type, message: m) { return friendly }
            if let m = m, !m.isEmpty { return m }
            if let c = code, !c.isEmpty { return c }
        }
        if let err = json["error"] as? String, !err.isEmpty {
            return friendlyProviderError(code: nil, type: nil, message: err) ?? err
        }
        if let m = json["message"] as? String, !m.isEmpty {
            let code = json["code"] as? String
            if let friendly = friendlyProviderError(code: code, type: nil, message: m) { return friendly }
            if let code = code, !code.isEmpty { return "\(m)（\(code)）" }
            return m
        }
        return nil
    }

    /// 把服务商（百炼 DashScope / 火山 Ark）最常见的两类错误翻成能照着办的中文；认不出的返回 nil、保留原话。
    /// 依据实测原文：百炼 Key 错 → code=invalid_api_key "Incorrect API key provided…"；
    /// 火山 Ark Key 错 → code=AuthenticationError "The API key format is incorrect…"；
    /// 百炼欠费 → code=Arrearage "…account is in good standing"；火山 Ark 欠费 → AccountOverdueError。
    static func friendlyProviderError(code: String?, type: String?, message: String?) -> String? {
        let c = (code ?? "").lowercased()
        let t = (type ?? "").lowercased()
        let m = (message ?? "").lowercased()
        let tag = (code?.isEmpty == false) ? "（\(code!)）" : ""

        if c == "invalid_api_key" || c == "invalidapikey" || c == "authenticationerror" || t == "unauthorized"
            || m.contains("incorrect api key") || m.contains("api key format is incorrect")
            || m.contains("didn't provide an api key") || m.contains("invalid api key") {
            return "API Key 无效，请检查是否复制完整\(tag)"
        }
        if c == "arrearage" || c == "accountoverdueerror" || c == "insufficient_quota"
            || m.contains("in good standing") || m.contains("arrearage") || m.contains("overdue")
            || m.contains("quota exceeded") || m.contains("enough balance") {
            return "账号欠费或免费额度已用完，请到服务商控制台检查\(tag)"
        }
        if c == "quotaexceeded" || c == "ratelimitexceeded" || c == "throttling" || c.hasPrefix("throttling.")
            || c == "limit_requests" || m.contains("rate limit") || m.contains("too many requests") {
            return "请求太频繁或额度超限，稍后再试\(tag)"
        }
        return nil
    }
}

import Foundation

/// 语音口令：用户在一句话的开头或结尾说「用英文」「翻译成英文」「English」，本次输出英文。
/// 识别完全用程序规则，不交给模型「领会」：
/// - 只认句首和句尾，中间出现一律当正文；
/// - 句首口令后面要有停顿（标点或空格），避免「用英文写信的人越来越少」这类正文被误认；
/// - 句尾的「用X / 说X」前面也要有停顿（或后面带「吧 / 好吗」），避免「我不太会用英文」被整句翻译；
/// - 口令前面紧跟「不要 / 别 / 不用」等否定词的不算（「这段话不要翻译成英文」是正文）；
/// - 去掉口令后正文要有实质内容，只有口令的整句当正文。
public struct OutputLanguageCommand: Equatable {
    public enum Position: String { case leading, trailing }

    public let target: OutputLanguage
    public let position: Position
    public let matchedPhrase: String
    /// 去掉口令后的正文（已去掉口令旁边的标点）
    public let strippedText: String

    public static let configKey = OutputLanguage.commandEnabledConfigKey
    static let negations: [String] = ["不要", "别", "不用", "不能", "无需", "不需要", "不必", "不会", "没有", "不是", "不", "没"]
    /// 正文至少要有这么多有意义的字符，否则整句当正文
    static let minimumContentCharacters = 3
    /// 句尾口令后面常带的语气词/客套（「用英文吧」「翻译成英文好吗」「用英文说」「in English please」），
    /// 匹配句尾时先剥掉这些再比对；只在剥完后紧邻的是口令时才算数，否则整句照旧按正文处理。
    static let trailingFillers: [String] = [
        "可以吗", "好吗", "好么", "行吗", "谢谢", "一下", "就行", "吧", "呗", "哦", "啊", "呀", "哈", "说", "please",
    ].sorted { $0.count > $1.count }

    public static func detect(in text: String, languages: [OutputLanguage] = OutputLanguage.builtin) -> OutputLanguageCommand? {
        let trimmed = trimEdges(text)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        // 句尾候选：原句，以及剥掉句尾语气词/客套后的句子（两者不同时才多一个候选）
        let withoutFillers = stripTrailingFillers(trimmed)
        let trailingCandidates: [String] = withoutFillers == trimmed ? [trimmed] : [trimmed, withoutFillers]
        var pairs: [(String, OutputLanguage)] = []
        for language in languages where language.enabled {
            for phrase in language.phrases {
                let p = phrase.trimmingCharacters(in: .whitespaces)
                if !p.isEmpty { pairs.append((p, language)) }
            }
        }
        pairs.sort { $0.0.count > $1.0.count }   // 长口令优先（"翻译成英文" 先于 "用英文"）

        for (phrase, language) in pairs {
            let p = phrase.lowercased()
            // 英文口令（English / in English）在英文句子里本来就是普通单词，空格不算停顿，必须有标点隔开
            let needsPunctuation = phrase.unicodeScalars.contains { isASCIILetter($0) }
            // 句尾（先试原句，再试剥掉语气词后的句子）
            for candidate in trailingCandidates where candidate.lowercased().hasSuffix(p) {
                let bodyEnd = candidate.index(candidate.endIndex, offsetBy: -phrase.count)
                let body = String(candidate[..<bodyEnd])
                let strippedFiller = candidate != trimmed
                let boundaryOK: Bool
                if needsPunctuation {
                    boundaryOK = hasPunctuationBoundary(body.unicodeScalars.reversed())
                } else if isAmbiguousPhrase(phrase) && !strippedFiller {
                    // 「用英文 / 说英文」在正文里很常见（「我不太会用英文」「开会都说英文」），
                    // 紧贴正文时不算口令：要么前面有停顿，要么后面带了「吧 / 好吗」这类口令语气。
                    boundaryOK = body.unicodeScalars.last.map(isSeparator) ?? false
                } else {
                    boundaryOK = true
                }
                if boundaryOK, !isNegated(before: body), let stripped = validBody(trimEdges(body)) {
                    return OutputLanguageCommand(target: language, position: .trailing, matchedPhrase: phrase, strippedText: stripped)
                }
            }
            // 句首：口令后面必须有停顿（中文口令：标点或空格；英文口令：标点）
            if lower.hasPrefix(p) {
                let afterStart = trimmed.index(trimmed.startIndex, offsetBy: phrase.count)
                let rest = String(trimmed[afterStart...])
                let boundaryOK = needsPunctuation
                    ? hasPunctuationBoundary(rest.unicodeScalars)
                    : (rest.unicodeScalars.first.map(isSeparator) ?? false)
                if boundaryOK, let stripped = validBody(trimEdges(rest)) {
                    return OutputLanguageCommand(target: language, position: .leading, matchedPhrase: phrase, strippedText: stripped)
                }
            }
        }
        return nil
    }

    // MARK: - 细节

    private static let separators = CharacterSet(charactersIn: "，。、！？；：,.!?;:\"“”‘’'()（）[]【】…—-~～ \t\n\r")

    static func isSeparator(_ scalar: UnicodeScalar) -> Bool { separators.contains(scalar) }
    static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool { (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value)) }
    /// 跳过空白后，紧邻的第一个字符是标点
    static func hasPunctuationBoundary<S: Sequence>(_ scalars: S) -> Bool where S.Element == UnicodeScalar {
        for sc in scalars {
            if sc == " " || sc == "\t" { continue }
            return isSeparator(sc)
        }
        return false
    }

    static func trimEdges(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.drop(while: isSeparator).reversed().drop(while: isSeparator).reversed()))
    }

    /// 反复剥掉句尾的语气词/客套及其旁边的标点（「用英文说吧。」→「用英文」）
    static func stripTrailingFillers(_ s: String) -> String {
        var current = trimEdges(s)
        while true {
            let lower = current.lowercased()
            guard let filler = trailingFillers.first(where: { lower.hasSuffix($0.lowercased()) }) else { return current }
            current = trimEdges(String(current.dropLast(filler.count)))
        }
    }

    /// 「用X / 说X」这类口令同时也是普通动宾短语；「翻译成X / 转X / X输出」则只会是口令。
    static func isAmbiguousPhrase(_ phrase: String) -> Bool {
        phrase.hasPrefix("用") || phrase.hasPrefix("说")
    }

    /// 口令前面（去掉标点后）紧跟否定词 → 是正文，不是口令
    static func isNegated(before body: String) -> Bool {
        let tail = trimEdges(body)
        return negations.contains { tail.hasSuffix($0) }
    }

    /// 正文要有实质内容
    static func validBody(_ body: String) -> String? {
        let meaningful = body.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }.count
        return meaningful >= minimumContentCharacters ? body : nil
    }
}

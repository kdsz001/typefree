import XCTest
@testable import VoicePolishCore

final class OutputLanguageCommandTests: XCTestCase {
    private func detect(_ s: String) -> OutputLanguageCommand? { OutputLanguageCommand.detect(in: s) }

    func testTrailingCommands() {
        let cases: [(String, String)] = [
            ("帮我把这个方案发给团队，明天上午之前确认，翻译成英文", "帮我把这个方案发给团队，明天上午之前确认"),
            ("帮我把这个方案发给团队，明天上午之前确认翻译成英文", "帮我把这个方案发给团队，明天上午之前确认"),
            ("明天三点开会 用英文", "明天三点开会"),
            ("明天三点开会。用英文。", "明天三点开会"),
            ("明天三点开会，English", "明天三点开会"),
            ("明天三点开会. english", "明天三点开会"),
            ("明天三点开会，in English", "明天三点开会"),
            ("明天三点开会，翻成英文", "明天三点开会"),
            ("明天三点开会，转英文", "明天三点开会"),
            ("明天三点开会，英文输出", "明天三点开会"),
            ("明天三点开会，用英语", "明天三点开会"),
            ("这个季度目标是留存做到 40%，翻译成英语！", "这个季度目标是留存做到 40%"),
        ]
        for (input, body) in cases {
            let cmd = detect(input)
            XCTAssertNotNil(cmd, "应识别：\(input)")
            XCTAssertEqual(cmd?.position, .trailing, input)
            XCTAssertEqual(cmd?.strippedText, body, input)
        }
    }

    func testLeadingCommands() {
        let cases: [(String, String)] = [
            ("用英文，帮我把方案发给团队", "帮我把方案发给团队"),
            ("用英文 帮我把方案发给团队", "帮我把方案发给团队"),
            ("翻译成英文：明天三点开会，二楼会议室", "明天三点开会，二楼会议室"),
            ("English, remind me to call mom at eight", "remind me to call mom at eight"),
            ("用英语。这周进展：功能做完了", "这周进展：功能做完了"),
        ]
        for (input, body) in cases {
            let cmd = detect(input)
            XCTAssertNotNil(cmd, "应识别：\(input)")
            XCTAssertEqual(cmd?.position, .leading, input)
            XCTAssertEqual(cmd?.strippedText, body, input)
        }
    }

    func testMiddleIsContent() {
        let inputs = [
            "帮我把这段翻译成英文再发给他",
            "他说用英文写邮件比较正式，我同意",
            "我想学 English，你有什么建议",
            "这个文档需要有英文版和中文版",
        ]
        for s in inputs { XCTAssertNil(detect(s), "中间出现应当正文：\(s)") }
    }

    func testLeadingWithoutPauseIsContent() {
        // 句首没有停顿：可能是正文（「用英文写信的人越来越少」）
        XCTAssertNil(detect("用英文写信的人越来越少"))
        XCTAssertNil(detect("翻译成英文的版本明天给你"))
        XCTAssertNil(detect("English is hard to learn for many people"))
        XCTAssertNil(detect("I want to learn English"))
        XCTAssertNil(detect("我想学 English"))
        XCTAssertNil(detect("please write this in English"))
        XCTAssertNil(detect("明天三点开会 English"))   // 英文口令没有标点隔开，可能只是句子里的单词
    }

    func testNegationIsContent() {
        let inputs = [
            "这段话不要翻译成英文",
            "这段话，不要翻译成英文。",
            "别用英文",
            "这次不用英文",
            "这份合同不需要翻译成英语",
            "他不会说英文",
        ]
        for s in inputs { XCTAssertNil(detect(s), "否定应当正文：\(s)") }
    }

    func testCommandOnlyOrTooShortIsContent() {
        XCTAssertNil(detect("翻译成英文"))
        XCTAssertNil(detect("用英文。"))
        XCTAssertNil(detect("English"))
        XCTAssertNil(detect("好 翻译成英文"))   // 正文只有一个字
        XCTAssertNotNil(detect("好的收到 翻译成英文"))
    }

    func testLongestPhraseWins() {
        let cmd = detect("明天开会，翻译成英文")
        XCTAssertEqual(cmd?.matchedPhrase, "翻译成英文")
        XCTAssertEqual(cmd?.strippedText, "明天开会")
    }

    func testCustomPhrases() {
        let custom = [OutputLanguage(id: "custom-1", name: "英文版", tag: "EN", phrases: ["转英文版"], enabled: true)]
        XCTAssertNotNil(OutputLanguageCommand.detect(in: "明天开会，转英文版", languages: custom))
        XCTAssertNil(OutputLanguageCommand.detect(in: "明天开会，翻译成英文", languages: custom))
    }

    func testOtherLanguagesAndDisabled() {
        XCTAssertEqual(detect("明天三点开会，翻译成日文")?.target.id, "ja")
        XCTAssertEqual(detect("用韩语，明天三点开会")?.target.id, "ko")
        XCTAssertEqual(detect("明天三点开会，用中文")?.target.id, "zh")
        XCTAssertEqual(detect("明天三点开会，日本語")?.target.id, "ja")
        XCTAssertNil(detect("明天三点开会，翻译成法语"), "法语默认关闭")
        var langs = OutputLanguage.builtin
        langs[langs.firstIndex { $0.id == "fr" }!].enabled = true
        XCTAssertEqual(OutputLanguageCommand.detect(in: "明天三点开会，翻译成法语", languages: langs)?.target.id, "fr")
        XCTAssertNil(detect("他不会说日语"))
        XCTAssertNil(detect("我在学日语"))
    }

    func testConfiguredMergesStoredOverrides() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = VoicePolishConfig(configDir: dir)
        config.save(values: [OutputLanguage.listConfigKey: [
            ["id": "ja", "enabled": false],
            ["id": "custom-abc", "name": "泰语", "phrases": ["用泰语", "Thai"], "enabled": true],
        ]])
        let list = OutputLanguage.configured(config: config)
        XCTAssertEqual(list.first { $0.id == "ja" }?.enabled, false)
        XCTAssertEqual(list.first { $0.id == "ja" }?.phrases, OutputLanguage.builtin.first { $0.id == "ja" }?.phrases)
        XCTAssertEqual(list.last?.name, "泰语")
        XCTAssertEqual(list.last?.tag, "泰语")
        XCTAssertEqual(OutputLanguageCommand.detect(in: "明天开会，用泰语", languages: list)?.target.name, "泰语")
        XCTAssertNil(OutputLanguageCommand.detect(in: "明天开会，翻译成日文", languages: list))
        config.save(value: "en", forKey: OutputLanguage.defaultConfigKey)
        XCTAssertEqual(OutputLanguage.defaultLanguage(config: config)?.id, "en")
    }

    func testTrailingFillersAfterCommand() {
        let cases: [(String, String, String)] = [
            ("明天开会用英文吧", "明天开会", "用英文"),
            ("明天三点开会，翻译成英文好吗", "明天三点开会", "翻译成英文"),
            ("明天三点开会，翻译成英文好吗？", "明天三点开会", "翻译成英文"),
            ("明天开会，用英文说", "明天开会", "用英文"),
            ("明天开会，用英文谢谢", "明天开会", "用英文"),
            ("明天开会，用英文说吧。", "明天开会", "用英文"),
            ("明天开会，翻译成英文一下", "明天开会", "翻译成英文"),
            ("明天开会，用英语可以吗", "明天开会", "用英语"),
            ("明天三点开会，in English please", "明天三点开会", "in English"),
            ("明天三点开会，English, please.", "明天三点开会", "English"),
        ]
        for (input, body, phrase) in cases {
            let cmd = detect(input)
            XCTAssertNotNil(cmd, "应识别：\(input)")
            XCTAssertEqual(cmd?.position, .trailing, input)
            XCTAssertEqual(cmd?.matchedPhrase, phrase, input)
            XCTAssertEqual(cmd?.strippedText, body, input)
        }
    }

    func testTrailingFillersDoNotLeakIntoContent() {
        // 语气词前面不是口令 → 整句是正文，什么都不剥
        XCTAssertNil(detect("这个词用英文怎么说"))
        XCTAssertNil(detect("我打算用英文写这篇文章的开头"))
        XCTAssertNil(detect("他说用英文写邮件比较正式，我同意吧"))
        XCTAssertNil(detect("明天开会说"))
        XCTAssertNil(detect("明天开会好吗"))
        // 剥掉语气词后紧跟的是否定词 → 仍是正文
        XCTAssertNil(detect("这段话不要翻译成英文吧"))
        XCTAssertNil(detect("这次别用英文说"))
        // 只有口令 + 语气词，没正文 → 正文
        XCTAssertNil(detect("翻译成英文好吗"))
        XCTAssertNil(detect("用英文谢谢"))
    }

    func testNoisyASRPunctuation() {
        XCTAssertEqual(detect("明天开会。。翻译成英文，")?.strippedText, "明天开会")
        XCTAssertEqual(detect("  用英文， 明天开会  ")?.strippedText, "明天开会")
    }

    // MARK: - Pipeline 决策（cloudOnly / omni 共用）

    func testResolveOutputLanguagePrefersCommandThenDefault() {
        let en = OutputLanguage.builtin.first { $0.id == "en" }!
        let ja = OutputLanguage.builtin.first { $0.id == "ja" }!
        let cmd = detect("明天开会，用英文吧")!

        // omni：只认口令，不套默认语言
        let omniHit = VoicePolishPipeline.resolveOutputLanguage(rawText: "明天开会，用英文吧", command: cmd, defaultLanguage: nil)
        XCTAssertEqual(omniHit?.target.id, "en")
        XCTAssertEqual(omniHit?.text, "明天开会")
        XCTAssertNil(VoicePolishPipeline.resolveOutputLanguage(rawText: "明天开会", command: nil, defaultLanguage: nil))

        // cloudOnly：口令优先于默认语言；没口令才用默认语言，正文原样
        let both = VoicePolishPipeline.resolveOutputLanguage(rawText: "明天开会，用英文吧", command: cmd, defaultLanguage: ja)
        XCTAssertEqual(both?.target.id, "en")
        XCTAssertEqual(both?.text, "明天开会")
        let onlyDefault = VoicePolishPipeline.resolveOutputLanguage(rawText: "明天开会", command: nil, defaultLanguage: en)
        XCTAssertEqual(onlyDefault?.target.id, "en")
        XCTAssertEqual(onlyDefault?.text, "明天开会")
    }

    // 「用X / 说X」紧贴正文时是普通句子，不能把整句翻掉
    func testAmbiguousTrailingPhraseNeedsPause() {
        XCTAssertNil(detect("我不太会用英文"))
        XCTAssertNil(detect("我们开会都说英文"))
        XCTAssertNil(detect("他平时习惯用日语"))
        XCTAssertNil(detect("小朋友在家都说中文"))
        // 有停顿或口令语气 → 仍是口令
        XCTAssertEqual(detect("明天开会，用英文")?.strippedText, "明天开会")
        XCTAssertEqual(detect("明天开会用英文吧")?.strippedText, "明天开会")
        // 明确的翻译指令不受影响
        XCTAssertEqual(detect("明天开会翻译成英文")?.strippedText, "明天开会")
        XCTAssertEqual(detect("明天开会转英文")?.strippedText, "明天开会")
    }
}

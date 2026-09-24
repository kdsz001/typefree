import XCTest
@testable import VoicePolishCore

final class TermCorrectionTests: XCTestCase {

    private func apply(_ rules: [(String, [String])], _ text: String) -> String {
        AIPolisher.applyTermCorrections(rules.map { AIPolisher.TermCorrection(target: $0.0, variants: $0.1) }, to: text)
    }

    func testFixesVariant() {
        XCTAssertEqual(apply([("APIKey", ["APIK"])], "把 APIK 填进去"), "把 APIKey 填进去")
    }

    func testDoesNotCorruptTargetThatContainsVariant() {
        // 旧实现会把正确的 APIKey 改成 APIKeyey
        XCTAssertEqual(apply([("APIKey", ["APIK"])], "把 APIKey 填进去"), "把 APIKey 填进去")
        XCTAssertEqual(apply([("APIKey", ["APIK"])], "apikey 过期了"), "apikey 过期了")
    }

    func testLatinVariantMustBeWholeWord() {
        let rules = [("skill", ["SQL"])]
        XCTAssertEqual(apply(rules, "PostgreSQL 数据库"), "PostgreSQL 数据库")
        XCTAssertEqual(apply(rules, "MySQL"), "MySQL")
        XCTAssertEqual(apply(rules, "SQL 语句"), "skill 语句")
        XCTAssertEqual(apply(rules, "用SQL查"), "用skill查")   // 紧挨中文照样算整词
    }

    func testChineseVariantReplacedInsideSentence() {
        XCTAssertEqual(apply([("小肚控制台", ["小度控制台", "小豆控制台"])], "打开小度控制台看看"), "打开小肚控制台看看")
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(apply([("Claude Code", ["Cloud code"])], "cloud Code 真好用"), "Claude Code 真好用")
    }

    func testLongerVariantWinsAndReplacementIsNotReprocessed() {
        // 旧实现逐条整段替换：先得到 Claude Code，再被 Code→Codex 改成 Claude Codex
        let rules = [("Claude Code", ["Cloud code"]), ("Codex", ["Code"])]
        XCTAssertEqual(apply(rules, "Cloud code"), "Claude Code")
        XCTAssertEqual(apply([("OpenClaw", ["Open Cloud"]), ("Claude", ["Cloud"])], "Open Cloud 和 Cloud"), "OpenClaw 和 Claude")
    }

    func testCaseOnlyVariantNormalizesCasing() {
        let rules = [("ChatGPT", ["chatgpt"])]
        XCTAssertEqual(apply(rules, "用 chatgpt 写"), "用 ChatGPT 写")
        XCTAssertEqual(apply(rules, "用 ChatGPT 写"), "用 ChatGPT 写")
    }

    func testNoRulesKeepsText() {
        XCTAssertEqual(apply([], "原样"), "原样")
        XCTAssertEqual(apply([("热词", [])], "热磁"), "热磁")
    }

    // 中文误写不能把别的词拦腰改掉
    func testChineseVariantDoesNotSplitAnotherWord() {
        let rules = [("徐相", ["徐向"])]
        XCTAssertEqual(apply(rules, "我跟徐向说了"), "我跟徐相说了")
        XCTAssertEqual(apply(rules, "徐向前是元帅"), "徐向前是元帅")
        XCTAssertEqual(apply([("豆包", ["斗包"])], "明天找斗包聊聊"), "明天找豆包聊聊")
        XCTAssertEqual(apply([("北大", ["北京大"])], "今天去北京大学开会"), "今天去北京大学开会")
    }
}

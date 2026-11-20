import XCTest
@testable import VoicePolishCore

final class RecordingFlowPolicyTests: XCTestCase {

    // MARK: - 修1：录音被判没声音

    func testShortSilenceStaysQuiet() {
        // 误触、按一下就松：照旧安静收起
        XCTAssertFalse(RecordingFlowPolicy.shouldReportSilence(audioSeconds: 0))
        XCTAssertFalse(RecordingFlowPolicy.shouldReportSilence(audioSeconds: 0.5))
        XCTAssertFalse(RecordingFlowPolicy.shouldReportSilence(audioSeconds: 2.9))
    }

    func testLongSilenceIsReported() {
        XCTAssertTrue(RecordingFlowPolicy.shouldReportSilence(audioSeconds: 3))
        XCTAssertTrue(RecordingFlowPolicy.shouldReportSilence(audioSeconds: 120), "说了 2 分钟被判没声音必须提示")
    }

    func testSilentHintOnlyMentionsHistoryWhenSaved() {
        let saved = RecordingFlowPolicy.silentRecordingHint(savedToHistory: true)
        let notSaved = RecordingFlowPolicy.silentRecordingHint(savedToHistory: false)
        XCTAssertTrue(saved.contains("检查麦克风"))
        XCTAssertTrue(saved.contains("已存进历史"))
        XCTAssertTrue(notSaved.contains("检查麦克风"))
        XCTAssertFalse(notSaved.contains("历史"), "没存进历史（不保存数据 / 写不进）时不能说已存")
    }

    // MARK: - 优10：润色总封顶

    func testPolishWaitCapIsConservative() {
        // 实测润色 ≈ 0.8s + 字数/100；封顶要远高于它，只截住真卡住的
        for chars in [0, 14, 90, 300, 680, 1500, 3000] {
            let measured = 0.8 + Double(chars) / 100
            XCTAssertGreaterThanOrEqual(RecordingFlowPolicy.polishWaitCap(characters: chars), max(25, measured * 2.5),
                                        "\(chars) 字的正常慢润色不能被掐掉")
        }
        XCTAssertEqual(RecordingFlowPolicy.polishWaitCap(characters: 0), 25, accuracy: 0.001)
        XCTAssertEqual(RecordingFlowPolicy.polishWaitCap(characters: 100), 28, accuracy: 0.001)
        XCTAssertEqual(RecordingFlowPolicy.polishWaitCap(characters: 680), 45.4, accuracy: 0.001)
        XCTAssertEqual(RecordingFlowPolicy.polishWaitCap(characters: 10_000), 90, accuracy: 0.001, "最多 90 秒")
        XCTAssertLessThan(RecordingFlowPolicy.polishWaitCap(characters: 30), 60, "短句卡住时要比以前的 60 秒早出原文")
    }

    func testPolishTimeoutReason() {
        XCTAssertEqual(RecordingFlowPolicy.polishTimeoutReason(cap: 28), "网络太慢，等了 28 秒没整理完")
    }

    // MARK: - 优10：录音中换麦克风后采集没接上

    func testCaptureInterruptedHints() {
        let hint = RecordingFlowPolicy.silentRecordingHint(savedToHistory: true, captureInterrupted: true)
        XCTAssertTrue(hint.contains("麦克风断开"))
        XCTAssertTrue(hint.contains("已存进历史"))
        XCTAssertFalse(RecordingFlowPolicy.silentRecordingHint(savedToHistory: false, captureInterrupted: true).contains("历史"))
        XCTAssertLessThanOrEqual(RecordingFlowPolicy.captureInterruptedCaption.count, 4, "录音胶囊窄，最多放 4 个字")
    }

    // MARK: - 优10：试用到期那一刻的长录音

    func testTrialEndedDuringRecordingNeedsAllConditions() {
        XCTAssertTrue(RecordingFlowPolicy.trialEndedDuringRecording(startedInTrial: true, trialExpiredNow: true, ownKeyConfigured: false, activated: false))
        XCTAssertFalse(RecordingFlowPolicy.trialEndedDuringRecording(startedInTrial: false, trialExpiredNow: true, ownKeyConfigured: false, activated: false),
                       "开始录音时试用早就结束了：不是这次到期的，报错照旧")
        XCTAssertFalse(RecordingFlowPolicy.trialEndedDuringRecording(startedInTrial: true, trialExpiredNow: false, ownKeyConfigured: false, activated: false))
        XCTAssertFalse(RecordingFlowPolicy.trialEndedDuringRecording(startedInTrial: true, trialExpiredNow: true, ownKeyConfigured: true, activated: false),
                       "填了自己的 Key：缺凭证是 Key 的问题")
        XCTAssertFalse(RecordingFlowPolicy.trialEndedDuringRecording(startedInTrial: true, trialExpiredNow: true, ownKeyConfigured: false, activated: true))
    }

    func testMissingCredentialsRewrittenOnlyWhenTrialEnded() {
        let missing = CloudASRTranscriber.TranscriptionError.missingCredentials.errorDescription!
        let withSuffix = missing + " · 录音已存进历史，可点「···」→「重试」"
        XCTAssertEqual(RecordingFlowPolicy.recognitionErrorMessage(withSuffix, trialEndedDuringRecording: true),
                       RecordingFlowPolicy.trialEndedMessage + " · 录音已存进历史，可点「···」→「重试」")
        XCTAssertEqual(RecordingFlowPolicy.recognitionErrorMessage(missing, trialEndedDuringRecording: true),
                       RecordingFlowPolicy.trialEndedMessage)
        XCTAssertEqual(RecordingFlowPolicy.recognitionErrorMessage(missing, trialEndedDuringRecording: false), missing)
        XCTAssertEqual(RecordingFlowPolicy.recognitionErrorMessage("识别超时", trialEndedDuringRecording: true), "识别超时",
                       "别的错误不动")
    }

    func testIsMissingCredentials() {
        XCTAssertTrue(RecordingFlowPolicy.isMissingCredentials(CloudASRTranscriber.TranscriptionError.missingCredentials))
        XCTAssertFalse(RecordingFlowPolicy.isMissingCredentials(CloudASRTranscriber.TranscriptionError.timeout))
        XCTAssertFalse(RecordingFlowPolicy.isMissingCredentials(URLError(.timedOut)))
    }
}

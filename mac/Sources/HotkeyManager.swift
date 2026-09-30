import Cocoa
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension Notification.Name {
    static let voicePolishHotkeyDidChange = Notification.Name("VoicePolishHotkeyDidChange")
    /// 用户在系统设置里开启了辅助功能（App 运行中检测到，无需重启）
    static let voicePolishAccessibilityGranted = Notification.Name("VoicePolishAccessibilityGranted")
}

enum RecordingHotkeyBehavior {
    static let tapToggleConfigKey = "recording_hotkey_tap_toggle_enabled"
    static let defaultTapToggleEnabled = true
    // 区分「单击（按一下开始/再按一下停）」与「长按说话（松手即停）」的门槛。
    // 原 0.30 太靠前：用户的「单击」手感常落在 0.3 秒上下，偶尔越线被误判成长按、松手秒停，
    // 表现为「胶囊一闪而过」。放宽到 0.50，让 0.3~0.4 秒的单击稳定算单击，长按需按住超过半秒。
    static let holdThreshold: TimeInterval = 0.50

    // 松手要等多久才算数。平时 0.08 秒：滤掉修饰键信号的瞬间抖动，松手即停不拖慢。
    static let releaseConfirmDelay: TimeInterval = 0.08
    // 刚按下的头 1.5 秒里放宽到 0.35 秒。按得慢、键没压实时，按键信号会「松开零点几秒又按回去」
    // （Ray 2026-09-23 两次：按下后 0.1～1 秒内出现 0.04～0.28 秒的松开），以前被当成松手——
    // 录音刚开始就停（或被当成单击、紧接着那下按回去又被当成第二下停掉），听着就是「开始、结束」一起响。
    // 这段时间里 0.35 秒内按回去就当一直按着；说了一会儿以后的松手仍按 0.08 秒确认，收尾不变慢。
    static let earlyPressWindow: TimeInterval = 1.5
    static let earlyReleaseConfirmDelay: TimeInterval = 0.35

    static var isTapToggleEnabled: Bool {
        VoicePolishConfig.shared.bool(
            forKey: tapToggleConfigKey,
            defaultValue: defaultTapToggleEnabled
        )
    }
}

enum RecordingHotkeyModifier: String, CaseIterable {
    case option
    case command
    case control
    case shift
    case fn
    case rightCommand

    static let configKey = "recording_hotkey_modifier"

    static var current: RecordingHotkeyModifier {
        let raw = VoicePolishConfig.shared.string(forKey: configKey) ?? RecordingHotkeyModifier.option.rawValue
        return RecordingHotkeyModifier(rawValue: raw) ?? .option
    }

    var displayName: String {
        switch self {
        case .option: return "Option"
        case .command: return "Command"
        case .control: return "Control"
        case .shift: return "Shift"
        case .fn: return "Fn"
        case .rightCommand: return "右 Command"
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .command, .rightCommand: return "⌘"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .fn: return "fn"
        }
    }

    var menuTitle: String {
        displayName
    }

    var symbolName: String {
        switch self {
        case .option: return "option"
        case .command, .rightCommand: return "command"
        case .control: return "control"
        case .shift: return "shift"
        case .fn: return "function"
        }
    }

    var eventFlag: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .command, .rightCommand: return .command
        case .control: return .control
        case .shift: return .shift
        case .fn: return .function
        }
    }

    var cgFlag: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .command, .rightCommand: return .maskCommand
        case .control: return .maskControl
        case .shift: return .maskShift
        case .fn: return .maskSecondaryFn
        }
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(eventFlag) else { return false }
        if self == .rightCommand {
            return event.keyCode == 54 || Self.currentPhysicalKeyCode() == 54
        }
        return true
    }

    static func capture(from event: NSEvent) -> RecordingHotkeyModifier? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let allowed: [(NSEvent.ModifierFlags, RecordingHotkeyModifier)] = [
            (.option, .option),
            (.command, event.keyCode == 54 ? .rightCommand : .command),
            (.control, .control),
            (.shift, .shift),
            (.function, .fn),
        ]
        let matches = allowed.filter { flags.contains($0.0) }
        guard matches.count == 1 else { return nil }

        let allowedMask: NSEvent.ModifierFlags = [.option, .command, .control, .shift, .function]
        guard flags.subtracting(allowedMask).isEmpty else { return nil }
        return matches[0].1
    }

    private static func currentPhysicalKeyCode() -> UInt16? {
        guard let event = NSApp.currentEvent, event.type == .flagsChanged else { return nil }
        return event.keyCode
    }
}

struct RecordingHotkeyCustomShortcut: Equatable {
    static let keyCodeConfigKey = "recording_hotkey_custom_key_code"
    static let modifiersConfigKey = "recording_hotkey_custom_modifiers"
    static let keyDisplayConfigKey = "recording_hotkey_custom_key_display"

    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let keyDisplay: String

    var displayName: String {
        Self.symbols(for: modifiers) + keyDisplay
    }

    var conflictWarning: String? {
        let normalized = Self.normalized(modifiers)
        if keyCode == 49 && normalized == .command {
            return "⌘ Space 通常会被系统输入法或 Spotlight 占用，建议换一个组合。"
        }
        if keyCode == 48 && normalized.contains(.command) {
            return "⌘ Tab 通常会被系统用于切换 App，建议换一个组合。"
        }
        if keyDisplay.count == 1 && normalized == .command {
            return "单独使用 ⌘ 加字母，可能和常用 App 菜单快捷键冲突。"
        }
        return nil
    }

    func matchesKeyDown(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && Self.normalized(event.modifierFlags) == Self.normalized(modifiers)
    }

    func matchesKeyUp(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode
    }

    static var saved: RecordingHotkeyCustomShortcut? {
        let config = VoicePolishConfig.shared
        guard let keyCodeRaw = config.string(forKey: keyCodeConfigKey),
              let keyCode = UInt16(keyCodeRaw),
              let modifiersRaw = config.string(forKey: modifiersConfigKey),
              let modifiersValue = UInt(modifiersRaw) else { return nil }
        let display = config.string(forKey: keyDisplayConfigKey) ?? "Key \(keyCode)"
        return RecordingHotkeyCustomShortcut(
            keyCode: keyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: modifiersValue),
            keyDisplay: display
        )
    }

    static func save(_ shortcut: RecordingHotkeyCustomShortcut) {
        let config = VoicePolishConfig.shared
        config.save(value: String(shortcut.keyCode), forKey: keyCodeConfigKey)
        config.save(value: String(shortcut.modifiers.rawValue), forKey: modifiersConfigKey)
        config.save(value: shortcut.keyDisplay, forKey: keyDisplayConfigKey)
    }

    static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.option, .command, .control, .shift, .function])
    }

    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        let normalized = normalized(flags)
        if normalized.contains(.control) { result += "⌃" }
        if normalized.contains(.option) { result += "⌥" }
        if normalized.contains(.shift) { result += "⇧" }
        if normalized.contains(.command) { result += "⌘" }
        if normalized.contains(.function) { result += "fn" }
        return result
    }

    static func keyDisplayName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Esc"
        case 76: return "Enter"
        case 117: return "Forward Delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            let raw = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? "Key \(event.keyCode)" : raw.uppercased()
        }
    }
}

enum RecordingHotkeyShortcut {
    case modifier(RecordingHotkeyModifier)
    case custom(RecordingHotkeyCustomShortcut)

    static let modeConfigKey = "recording_hotkey_mode"

    static var current: RecordingHotkeyShortcut {
        if VoicePolishConfig.shared.string(forKey: modeConfigKey) == "custom",
           let custom = RecordingHotkeyCustomShortcut.saved {
            return .custom(custom)
        }
        return .modifier(RecordingHotkeyModifier.current)
    }

    var displayName: String {
        switch self {
        case .modifier(let modifier): return "\(modifier.symbol) \(modifier.displayName)"
        case .custom(let shortcut): return shortcut.displayName
        }
    }

    var debugName: String {
        switch self {
        case .modifier(let modifier): return modifier.rawValue
        case .custom(let shortcut): return "custom(\(shortcut.displayName))"
        }
    }

    static func useModifier(_ modifier: RecordingHotkeyModifier) {
        let config = VoicePolishConfig.shared
        config.save(value: "modifier", forKey: modeConfigKey)
        config.save(value: modifier.rawValue, forKey: RecordingHotkeyModifier.configKey)
    }

    static func useCustom(_ shortcut: RecordingHotkeyCustomShortcut) {
        let config = VoicePolishConfig.shared
        RecordingHotkeyCustomShortcut.save(shortcut)
        config.save(value: "custom", forKey: modeConfigKey)
    }
}

class HotkeyManager {
    private enum RecordingGestureState {
        case idle
        case pressing(startedAt: TimeInterval, sawChord: Bool)
        case holdRecording(startedAt: TimeInterval, sawChord: Bool)
        case latchedRecording

        var debugName: String {
            switch self {
            case .idle: return "idle"
            case .pressing(_, let sawChord): return "pressing(chord=\(sawChord))"
            case .holdRecording(_, let sawChord): return "holdRecording(chord=\(sawChord))"
            case .latchedRecording: return "latchedRecording"
            }
        }
    }

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private let onStart: () -> Bool
    private let onStop: () -> Void
    private let isRecording: () -> Bool

    private var lastEventTime: TimeInterval = 0
    private var lastProcessedModifierDown = false   // 上一次「已处理」事件的方向，用于只去重同方向的重复
    private var lastShortcutEventTime: TimeInterval = 0
    private var lastProcessedShortcutDown = false
    private var configuredShortcut = RecordingHotkeyShortcut.current
    private var tapToggleEnabled = RecordingHotkeyBehavior.isTapToggleEnabled
    private var wasModifierDown = false
    private var gestureState: RecordingGestureState = .idle
    private var pendingStopWorkItem: DispatchWorkItem?
    private var holdPromotionWorkItem: DispatchWorkItem?
    /// 「真实松手时刻」（systemUptime）。在松手事件到达 confirmModifierRelease 时立即记下，
    /// 用来：①按真实「按下→松手」时长判定单击/长按，避免把确认延迟算进时长；
    /// ②在确认窗口内压制 hold 升级，防止临界单击被升级成长按后立刻停（胶囊一闪而过）。
    /// 每次新一轮按下（handleModifierPress）清空。
    private var releaseObservedAt: TimeInterval?
    /// 这一次物理按下的时刻（systemUptime），用来判断松手是不是发生在「刚按下」那一段
    private var pressStartedAt: TimeInterval?

    var debugLog: ((String) -> Void)?
    /// 手势定性：true=长按（松手即停）、false=单击切换（已锁定，需要再按/点按钮结束）
    var onGestureClassified: ((Bool) -> Void)?
    /// 键盘长按期间按 Esc：丢弃本次录音（对应鼠标长按的「拖开取消」）
    var onCancel: (() -> Void)?
    /// 按下后很快组合了别的键 → 这次按下只是快捷键的一部分，静默丢弃录音
    var onDiscard: (() -> Void)?

    init(
        onStart: @escaping () -> Bool,
        onStop: @escaping () -> Void,
        isRecording: @escaping () -> Bool
    ) {
        self.onStart = onStart
        self.onStop = onStop
        self.isRecording = isRecording
        startListening()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyDidChange),
            name: .voicePolishHotkeyDidChange,
            object: nil
        )
    }

    func stop() {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m); globalFlagsMonitor = nil }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        holdPromotionWorkItem?.cancel()
        holdPromotionWorkItem = nil
        NotificationCenter.default.removeObserver(self)
    }

    func recordingDidLeaveActiveState() {
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        holdPromotionWorkItem?.cancel()
        holdPromotionWorkItem = nil
        wasModifierDown = isConfiguredHotkeyCurrentlyPressed()
        gestureState = .idle
        releaseObservedAt = nil
        debugLog?("recording state reset by app")
    }

    private func startListening() {
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard case .modifier(let configuredModifier) = configuredShortcut else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let modifierDown = configuredModifier.matches(event)

        // 去重：全局 + 本地两个监听器会对「同一次」按下/松手各报一次，丢掉 50ms 内的重复。
        // 关键：只丢「同方向」的重复（都按下、或都松手）。绝不能只按时间一刀切——否则
        // 50ms 内的「闪电单击」那次方向相反的松手会被当成重复吞掉，状态卡在按下、录音停不下来。
        if now - lastEventTime < 0.05 && modifierDown == lastProcessedModifierDown { return }
        lastEventTime = now
        lastProcessedModifierDown = modifierDown

        let rawFlags = event.modifierFlags.rawValue

        debugLog?("flagsChanged: modifier=\(configuredModifier.rawValue) down=\(modifierDown) wasDown=\(wasModifierDown) state=\(gestureState.debugName) tapToggle=\(tapToggleEnabled) rawFlags=\(String(rawFlags, radix: 16)) keyCode=\(event.keyCode)")

        if modifierDown && !wasModifierDown {
            handleModifierPress(at: now)
        } else if !modifierDown && wasModifierDown {
            confirmModifierRelease()
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown: handleKeyDown(event)
        case .keyUp: handleKeyUp(event)
        default: break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard !event.isARepeat else { return }

        // 长按录音期间按 Esc → 取消（只在按住着的时候；单击锁定模式有叉号按钮）
        if event.keyCode == 53, isRecording() {
            switch gestureState {
            case .pressing, .holdRecording:
                debugLog?("Esc during hold → onCancel")
                gestureState = .idle
                onCancel?()
                return
            default:
                break
            }
        }

        if case .custom(let shortcut) = configuredShortcut {
            guard shortcut.matchesKeyDown(event) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastShortcutEventTime < 0.05 && lastProcessedShortcutDown { return }
            lastShortcutEventTime = now
            lastProcessedShortcutDown = true
            debugLog?("custom keyDown: shortcut=\(shortcut.displayName) wasDown=\(wasModifierDown) state=\(gestureState.debugName) tapToggle=\(tapToggleEnabled)")
            if !wasModifierDown {
                handleModifierPress(at: now)
            }
            return
        }

        guard case .modifier(let configuredModifier) = configuredShortcut,
              event.modifierFlags.contains(configuredModifier.eventFlag) else { return }

        switch gestureState {
        case .pressing:
            // 刚按下修饰键就接着按了别的键（⌘C、⌥←、Fn+↑…）：这是快捷键，不是要说话。
            // 静默丢掉这次录音，不发识别请求，也不弹「撤销」胶囊。
            holdPromotionWorkItem?.cancel()
            holdPromotionWorkItem = nil
            gestureState = .idle
            debugLog?("keyDown while pressing: chord keyCode=\(event.keyCode) → discard")
            onDiscard?()
        case .holdRecording(let startedAt, _):
            gestureState = .holdRecording(startedAt: startedAt, sawChord: true)
            debugLog?("keyDown while holding: chord keyCode=\(event.keyCode)")
        case .idle, .latchedRecording:
            break
        }
    }

    private func handleKeyUp(_ event: NSEvent) {
        guard case .custom(let shortcut) = configuredShortcut,
              shortcut.matchesKeyUp(event) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastShortcutEventTime < 0.05 && !lastProcessedShortcutDown { return }
        lastShortcutEventTime = now
        lastProcessedShortcutDown = false
        debugLog?("custom keyUp: shortcut=\(shortcut.displayName) wasDown=\(wasModifierDown) state=\(gestureState.debugName)")
        if wasModifierDown {
            confirmModifierRelease()
        }
    }

    private func handleModifierPress(at now: TimeInterval) {
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        holdPromotionWorkItem?.cancel()
        holdPromotionWorkItem = nil
        wasModifierDown = true
        releaseObservedAt = nil   // 新一轮手势开始：清掉上一轮可能残留的松手时刻
        pressStartedAt = now

        if case .latchedRecording = gestureState {
            gestureState = .idle
            debugLog?("→ onStop (tap toggle)")
            onStop()
            return
        }

        if isRecording() {
            gestureState = .idle
            debugLog?("→ onStop (recording already active)")
            onStop()
            return
        }

        guard case .idle = gestureState else { return }

        debugLog?("→ onStart")
        guard onStart() else {
            debugLog?("start ignored by app")
            return
        }

        gestureState = .pressing(startedAt: now, sawChord: false)
        scheduleHoldPromotion(startedAt: now)
    }

    private func scheduleHoldPromotion(
        startedAt: TimeInterval,
        after delay: TimeInterval = RecordingHotkeyBehavior.holdThreshold
    ) {
        holdPromotionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.wasModifierDown else { return }
            // 已观测到松手（正处于确认窗口内）→ 这是一次单击，绝不能升级成长按。
            // 否则临界单击（按住接近阈值）会被这里升级为 holdRecording，随后确认流程立刻 onStop，
            // 表现为「单击进入识别后立刻退出 / 胶囊一闪而过」。
            guard self.releaseObservedAt == nil else { return }
            guard case .pressing(let currentStart, let sawChord) = self.gestureState,
                  currentStart == startedAt else { return }

            self.gestureState = .holdRecording(startedAt: startedAt, sawChord: sawChord)
            self.debugLog?("promoted to holdRecording")
            self.onGestureClassified?(true)
        }

        holdPromotionWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: workItem
        )
    }

    private func confirmModifierRelease() {
        pendingStopWorkItem?.cancel()
        // 立即记下真实松手时刻（早于防抖确认）。用于按真实时长判定单击/长按，
        // 并在确认窗口内压制 hold 升级（见 scheduleHoldPromotion 的 releaseObservedAt 守卫）。
        let now = ProcessInfo.processInfo.systemUptime
        releaseObservedAt = now
        let isEarlyInPress = pressStartedAt.map { now - $0 < RecordingHotkeyBehavior.earlyPressWindow } ?? false
        let confirmDelay = isEarlyInPress
            ? RecordingHotkeyBehavior.earlyReleaseConfirmDelay
            : RecordingHotkeyBehavior.releaseConfirmDelay

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            let stillDown = self.isConfiguredHotkeyCurrentlyPressed()
            self.debugLog?("release check: stillDown=\(stillDown) wasDown=\(self.wasModifierDown) state=\(self.gestureState.debugName) wait=\(confirmDelay)")

            // 误报松手（键其实还按着 / 已经按回去了，多见于 flag 抖动、按得慢键没压实）：撤销这次松手记录，
            // 让长按升级照常进行，真正松手时再重新记一次。
            guard !stillDown else {
                self.releaseObservedAt = nil
                self.resumeHoldPromotionIfNeeded()
                return
            }

            self.wasModifierDown = false
            // 用真实松手时刻判定，而不是「确认 work item 执行时刻」（后者比真实松手晚一个确认窗口，
            // 会把单击时长算大、把单击误判成长按）。
            self.finishModifierRelease(at: self.releaseObservedAt ?? ProcessInfo.processInfo.systemUptime)
        }

        pendingStopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + confirmDelay, execute: workItem)
    }

    /// 松手被判成误报后：确认窗口里被压下去的长按升级要补上（到点立即升级，没到点按剩余时间排上），
    /// 否则手势会一直停在「按下未定性」。
    private func resumeHoldPromotionIfNeeded() {
        guard case .pressing(let startedAt, _) = gestureState else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        scheduleHoldPromotion(startedAt: startedAt, after: RecordingHotkeyBehavior.holdThreshold - elapsed)
    }

    private func finishModifierRelease(at now: TimeInterval) {
        holdPromotionWorkItem?.cancel()
        holdPromotionWorkItem = nil

        switch gestureState {
        case .pressing(let startedAt, let sawChord):
            let duration = now - startedAt
            if tapToggleEnabled && !sawChord && duration < RecordingHotkeyBehavior.holdThreshold {
                gestureState = .latchedRecording
                debugLog?("tap latched recording duration=\(String(format: "%.3f", duration))")
                onGestureClassified?(false)
            } else {
                gestureState = .idle
                debugLog?("→ onStop duration=\(String(format: "%.3f", duration)) chord=\(sawChord)")
                onStop()
            }
        case .holdRecording(let startedAt, let sawChord):
            gestureState = .idle
            debugLog?("→ onStop hold duration=\(String(format: "%.3f", now - startedAt)) chord=\(sawChord)")
            onStop()
        case .latchedRecording:
            debugLog?("release after latched recording")
        case .idle:
            debugLog?("release ignored in idle")
        }
    }

    private func isConfiguredHotkeyCurrentlyPressed() -> Bool {
        switch configuredShortcut {
        case .modifier(let modifier):
            return CGEventSource.flagsState(.combinedSessionState).contains(modifier.cgFlag)
        case .custom(let shortcut):
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(shortcut.keyCode))
        }
    }

    @objc private func hotkeyDidChange() {
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        holdPromotionWorkItem?.cancel()
        holdPromotionWorkItem = nil
        configuredShortcut = RecordingHotkeyShortcut.current
        tapToggleEnabled = RecordingHotkeyBehavior.isTapToggleEnabled
        wasModifierDown = isConfiguredHotkeyCurrentlyPressed()
        gestureState = .idle
        releaseObservedAt = nil
        pressStartedAt = nil
        debugLog?("hotkey settings changed: shortcut=\(configuredShortcut.debugName) tapToggle=\(tapToggleEnabled)")
    }
}

/// 录音期间按 Esc 取消，而且 Esc 只给 Typefree、不传给前台 App（工单 #1019）。
///
/// 以前 Esc 走的是全局监听：只能「旁听」，按键照样落到前台 App（可能把对方的弹窗、全屏、编辑状态也退掉了），
/// 而且只在「按住快捷键录音」时认，单击开始的录音、鼠标长按录音都不认。
/// 现在录音期间开一个系统级按键拦截：Esc 按下 → 取消录音并吞掉这次按键（连同它的抬起），别的键原样放行。
/// 不录音时拦截是关着的，对任何按键都没有影响。建拦截失败（没有辅助功能权限）时退回老的旁听方式。
final class EscapeInterceptor {
    var onEscape: (() -> Void)?
    var debugLog: ((String) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var active = false
    /// 吞掉了 Esc 按下，等着把对应的抬起也吞掉——否则前台 App 会收到一个孤零零的抬起
    private var swallowingKeyUp = false
    private var pendingDeactivate: DispatchWorkItem?

    private static let escapeKeyCode: Int64 = 53

    /// 录音开始时调用。返回拦截是否生效（false = 没权限等原因，调用方保留老的旁听方式）。
    @discardableResult
    func activate() -> Bool {
        pendingDeactivate?.cancel()
        pendingDeactivate = nil
        guard ensureTap(), let tap else { return false }
        active = true
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// 录音结束时调用。刚吞掉 Esc 按下、抬起还没来时稍等一下再关，把抬起也吞掉。
    func deactivate() {
        guard active else { return }
        if swallowingKeyUp {
            let work = DispatchWorkItem { [weak self] in self?.shutOff() }
            pendingDeactivate = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        } else {
            shutOff()
        }
    }

    private func shutOff() {
        pendingDeactivate = nil
        active = false
        swallowingKeyUp = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func ensureTap() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<EscapeInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            debugLog?("Esc 拦截建不起来（多半没有辅助功能权限），退回旁听方式")
            return false
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: created, enable: false)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统嫌回调太慢 / 用户输入时会把拦截关掉：录音中就重新打开
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if active, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp {
            guard swallowingKeyUp else { return Unmanaged.passUnretained(event) }
            swallowingKeyUp = false
            if pendingDeactivate != nil {
                pendingDeactivate?.cancel()
                shutOff()
            }
            return nil
        }
        guard active else { return Unmanaged.passUnretained(event) }
        swallowingKeyUp = true
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            debugLog?("Esc → cancel（按键已拦下，不传给前台 App）")
            DispatchQueue.main.async { [weak self] in self?.onEscape?() }
        }
        return nil
    }
}

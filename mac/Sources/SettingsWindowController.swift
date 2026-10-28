import Cocoa
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

protocol SettingsWindowDelegate: AnyObject {
    func currentProcessingMode() -> ProcessingMode
    func setProcessingMode(_ mode: ProcessingMode)
    func openAccessibilitySettings()
    func openMicrophoneSettings()
    func checkForUpdates(_ sender: Any?)
    func pendingUpdateInfo() -> TypefreeUpdateInfo?
    func showUpdateDetails(_ sender: Any?)
    /// 反馈页：最近一次录音时在用的软件名（定位「某个软件里不好用」）
    func recentTargetAppName() -> String?
    /// 反馈页：最近的调试日志片段（纯文本，随消息一起发给开发者）
    func debugLogTail() -> String
    /// 复用 App 的调试日志（同一个文件、同一套轮转），设置页的耗时诊断也写进去。
    func debugLog(_ message: String)
}

// MARK: - Color helpers

private extension NSColor {
    /// 供 HTML/CSS 使用的 #RRGGBB（先转 sRGB，避免色彩空间不同取不到分量）。
    var cssHex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - 更新说明渲染

/// 更新说明（appcast 里的 HTML：h3 小标题 / p 段落 / ul-li 要点 / strong）→ 富文本。
/// 「发现新版本」弹窗（AppDelegate）与设置里的「更新历史」共用，保证两处排版一致。
/// 排版按中文阅读调：行距 1.9（中文比英文更需要行距）、小标题与正文明确拉开层次、
/// 段落与列表项之间留白，避免整段糊成一片。
enum ReleaseNotesRenderer {
    static func attributed(fromHTML html: String,
                           bodyColor: NSColor,
                           headingColor: NSColor,
                           fontSize: CGFloat = 13) -> NSAttributedString? {
        // 颜色写进 CSS 而不是事后整段染色——否则小标题和正文只能是同一个颜色，层次就没了。
        let styled = """
        <style>
        body{font-family:-apple-system;font-size:\(fontSize)px;line-height:1.9;margin:0;color:\(bodyColor.cssHex)}
        h3{font-size:\(fontSize + 1)px;font-weight:600;color:\(headingColor.cssHex);margin:26px 0 10px;line-height:1.5}
        h3:first-child{margin-top:2px}
        p{margin:0 0 14px}
        ul{margin:0 0 14px 0;padding-left:18px}
        li{margin:0 0 8px;padding-left:2px}
        li:last-child{margin-bottom:0}
        strong{font-weight:600;color:\(headingColor.cssHex)}
        </style>
        \(html)
        """
        guard let data = styled.data(using: .utf8) else { return nil }
        return NSMutableAttributedString(
            html: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
    }
}

/// 自绘分段控件：统一圆角轨道 + 选中「浅底圆角药丸」，匹配设计稿的软填充观感。
/// 原生 NSSegmentedControl 会带系统竖线分隔、白底未选段、抬起式药丸，与设计稿不一致，故自绘。
/// 对外暴露与 NSSegmentedControl 一致的 `selectedSegment` 读写 + target/action。
final class VPSegmentedControl: NSView {
    private var containers: [NSView] = []
    private var itemLabels: [NSTextField] = []
    private let selBg: NSColor
    private let selBorder: NSColor
    private let selText: NSColor
    private let normalText: NSColor

    weak var target: AnyObject?
    var action: Selector?

    var selectedSegment: Int = 0 {
        didSet { restyle() }
    }

    init(labels: [String], trackBg: NSColor, trackBorder: NSColor,
         selBg: NSColor, selBorder: NSColor, selText: NSColor, normalText: NSColor,
         target: AnyObject?, action: Selector?) {
        self.selBg = selBg
        self.selBorder = selBorder
        self.selText = selText
        self.normalText = normalText
        self.target = target
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.setAppearanceBackground(trackBg)
        layer?.borderWidth = 1
        layer?.setAppearanceBorder(trackBorder)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.distribution = .fillEqually   // 三个选项等宽平铺，撑满整个控件宽度
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])

        for text in labels {
            let c = NSView()
            c.wantsLayer = true
            c.layer?.cornerRadius = 6
            c.translatesAutoresizingMaskIntoConstraints = false
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 12.5)
            l.alignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
                l.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
                l.topAnchor.constraint(equalTo: c.topAnchor, constant: 6),
                l.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -6),
            ])
            containers.append(c)
            itemLabels.append(l)
            stack.addArrangedSubview(c)
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func restyle() {
        for (i, c) in containers.enumerated() {
            let on = (i == selectedSegment)
            c.layer?.setAppearanceBackground((on ? selBg : NSColor.clear))
            c.layer?.borderWidth = on ? 1 : 0
            c.layer?.setAppearanceBorder((on ? selBorder : NSColor.clear))
            // 选中药丸加极淡阴影，模拟系统设置里「浮起」的白药丸
            c.layer?.setAppearanceShadow(NSColor.black)
            c.layer?.shadowOpacity = on ? 0.12 : 0
            c.layer?.shadowRadius = 1.5
            c.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
            itemLabels[i].textColor = on ? selText : normalText
            itemLabels[i].font = .systemFont(ofSize: 12.5, weight: on ? .semibold : .regular)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, c) in containers.enumerated() where c.convert(c.bounds, to: self).contains(p) {
            if i != selectedSegment {
                selectedSegment = i
                if let action = action { NSApp.sendAction(action, to: target, from: self) }
            }
            return
        }
    }
}

private final class HotkeyRecorderView: AppearanceObservingView {
    private let displayLabel = NSTextField(labelWithString: "点击这里，然后按下新的快捷键")
    private let hintLabel = NSTextField(labelWithString: "建议使用 Option / Command / Control / Shift 搭配一个按键")
    private(set) var shortcut: RecordingHotkeyCustomShortcut?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func flagsChanged(with event: NSEvent) {
        let modifiers = RecordingHotkeyCustomShortcut.normalized(event.modifierFlags)
        guard !modifiers.isEmpty else {
            hintLabel.stringValue = "先按住一个修饰键，再按一个普通键"
            return
        }
        displayLabel.stringValue = "\(RecordingHotkeyCustomShortcut.symbols(for: modifiers)) ..."
        hintLabel.stringValue = "继续按一个按键完成录入"
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        let modifiers = RecordingHotkeyCustomShortcut.normalized(event.modifierFlags)
        guard !modifiers.isEmpty else {
            shortcut = nil
            displayLabel.stringValue = "需要搭配修饰键"
            hintLabel.stringValue = "请至少按住 Option / Command / Control / Shift 中的一个"
            return
        }
        let keyDisplay = RecordingHotkeyCustomShortcut.keyDisplayName(for: event)
        let next = RecordingHotkeyCustomShortcut(
            keyCode: event.keyCode,
            modifiers: modifiers,
            keyDisplay: keyDisplay
        )
        shortcut = next
        displayLabel.stringValue = next.displayName
        hintLabel.stringValue = next.conflictWarning ?? "可以保存这个快捷键"
    }

    func setShortcut(_ shortcut: RecordingHotkeyCustomShortcut?) {
        self.shortcut = shortcut
        displayLabel.stringValue = shortcut?.displayName ?? "点击这里，然后按下新的快捷键"
        hintLabel.stringValue = "建议使用 Option / Command / Control / Shift 搭配一个按键"
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.setAppearanceBorder(NSColor.separatorColor)
        layer?.setAppearanceBackground(NSColor.controlBackgroundColor)

        displayLabel.font = .monospacedSystemFont(ofSize: 24, weight: .semibold)
        displayLabel.textColor = .labelColor
        displayLabel.alignment = .center
        displayLabel.lineBreakMode = .byTruncatingMiddle

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [displayLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 360),
            heightAnchor.constraint(equalToConstant: 118),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

// MARK: - Polish history store

final class PolishHistoryStore {
    private let logFileURL: URL

    init(logFileURL: URL = VoicePolishConfig.shared.configDirectoryURL.appendingPathComponent("polish_log.jsonl")) {
        self.logFileURL = logFileURL
    }

    var fileURL: URL { logFileURL }

    // 所有读-改-写都走 HistoryFileLock：pipeline 后台追加与这里的整文件重写此前互不相知，会丢条。

    func load(limit: Int = 100) -> [AIPolisher.PolishLog] {
        HistoryFileLock.withLock {
            pruneExpiredEntries()
            guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else {
                return []
            }
            let lines = content
                .split(separator: "\n")
                .suffix(limit)
                .reversed()
            let enc = HistoryCrypto.defaultEncryptor()
            return lines.compactMap { line in
                HistoryCrypto.decodeLine(String(line), enc: enc)
            }
        }
    }

    /// 导出历史为 Markdown（从新到旧，每条 `## 时间` + 整理后的文字）。
    /// 不受界面 500 条显示上限影响，读全部后按 `retention` 过滤时间范围
    /// （`.oneWeek` 近 7 天 / `.oneMonth` 近一个月 / `.forever` 全部，复用保留策略同一套判断）。
    /// 该范围内无记录返回 nil。
    func exportAllAsMarkdown(retention: AIPolisher.HistoryRetention = .forever) -> String? {
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return nil }
        let enc = HistoryCrypto.defaultEncryptor()
        let logs = content
            .split(separator: "\n")
            .reversed()
            .compactMap { HistoryCrypto.decodeLine(String($0), enc: enc) }
            .filter { AIPolisher.shouldKeepPolishLog($0, retention: retention) }
        guard !logs.isEmpty else { return nil }
        var out = "# Typefree 转写记录\n\n"
        for log in logs {
            if log.isAsk {
                out += "## \(log.time) · 问 AI\n**问：** \(log.asr)\n\n\(log.output.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
                continue
            }
            let polished = log.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = polished.isEmpty ? log.asr.trimmingCharacters(in: .whitespacesAndNewlines) : polished
            out += "## \(log.time)\n\(body)\n\n"
        }
        return out
    }

    func clear() {
        HistoryFileLock.withLock {
            try? FileManager.default.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
            AudioClipStore.defaultStore().deleteAll()  // 清空历史时一并删掉所有音频
        }
    }

    @discardableResult
    func pruneExpiredEntries() -> Int {
        let audioStore = AudioClipStore.defaultStore()
        return AIPolisher.pruneLogFile(
            at: logFileURL,
            retention: AIPolisher.currentHistoryRetention()
        ) { removed in
            audioStore.delete(fileName: removed.audioFile)
        }
    }

    /// 是否为同一条记录：有 id 用 id 比，否则比关键字段（旧数据兜底）。
    private func sameEntry(_ a: AIPolisher.PolishLog, _ b: AIPolisher.PolishLog) -> Bool {
        if let ia = a.id, let ib = b.id, !ia.isEmpty, !ib.isEmpty { return ia == ib }
        return a.time == b.time && a.app == b.app && a.asr == b.asr && a.output == b.output
    }

    /// 重写匹配到的那一行（用于重新润色/重新转写后更新 asr/output，其余字段保留）。
    @discardableResult
    func updateEntry(matching target: AIPolisher.PolishLog, newASR: String?, newOutput: String?) -> Bool {
        HistoryFileLock.withLock {
            guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return false }
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let enc = HistoryCrypto.defaultEncryptor() else { return false }
            var changed = false
            for (idx, line) in lines.enumerated() where !line.isEmpty {
                guard let log = HistoryCrypto.decodeLine(line, enc: enc),
                      sameEntry(log, target) else { continue }
                let updated = AIPolisher.PolishLog(
                    time: log.time, app: log.app,
                    asr: newASR ?? log.asr,
                    output: newOutput ?? log.output,
                    duration_ms: log.duration_ms,
                    input_tokens: log.input_tokens,
                    output_tokens: log.output_tokens,
                    id: log.id, audioFile: log.audioFile
                )
                if let s = HistoryCrypto.encodeLine(updated, enc: enc) {
                    lines[idx] = s
                    changed = true
                }
                break
            }
            guard changed else { return false }
            try? lines.joined(separator: "\n").write(to: logFileURL, atomically: true, encoding: .utf8)
            return true
        }
    }

    /// 删除匹配到的那一行，并删掉其音频。
    @discardableResult
    func deleteEntry(matching target: AIPolisher.PolishLog) -> Bool {
        HistoryFileLock.withLock {
            guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return false }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let enc = HistoryCrypto.defaultEncryptor()
            var kept: [String] = []
            var removed = false
            for line in lines where !line.isEmpty {
                if !removed,
                   let log = HistoryCrypto.decodeLine(line, enc: enc),
                   sameEntry(log, target) {
                    removed = true
                    AudioClipStore.defaultStore().delete(fileName: log.audioFile)
                    continue
                }
                kept.append(line)
            }
            guard removed else { return false }
            let next = kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
            try? next.write(to: logFileURL, atomically: true, encoding: .utf8)
            return true
        }
    }
}

// MARK: - Internal views

/// 自适应多行标签：布局时把 preferredMaxLayoutWidth 同步成实际宽度，
/// 避免写死固定值估错高度导致长文本被截断。
private final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SidebarRow: NSView {
    typealias Page = SettingsWindowController.Page

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let indicator = NSView()

    let page: Page
    var onClick: ((Page) -> Void)?
    private var theme: VPTheme = .automatic
    private var hovering = false
    var isSelected: Bool = false { didSet { applyState() } }

    init(page: Page, count: String?) {
        self.page = page
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false

        let symbol = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: nil)
        let configured = symbol?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        iconView.image = configured ?? symbol
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = page.title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.stringValue = count ?? ""
        countLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.isHidden = (count ?? "").isEmpty

        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 1.5
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.alphaValue = 0

        addSubview(indicator)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -2),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 3),
            indicator.heightAnchor.constraint(equalToConstant: 14),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func updateCount(_ count: String?) {
        countLabel.stringValue = count ?? ""
        countLabel.isHidden = (count ?? "").isEmpty
    }

    func apply(theme: VPTheme) {
        self.theme = theme
        indicator.layer?.setAppearanceBackground(theme.accent)
        applyState()
    }

    private func applyState() {
        let bg: NSColor
        if isSelected {
            bg = theme.sidebarSel
        } else if hovering {
            bg = theme.sidebarHover
        } else {
            bg = .clear
        }
        layer?.setAppearanceBackground(bg)
        iconView.contentTintColor = isSelected ? theme.accent : theme.text3
        titleLabel.font = .systemFont(ofSize: 13, weight: isSelected ? .medium : .regular)
        titleLabel.textColor = isSelected ? theme.text : theme.text2
        countLabel.textColor = theme.text3
        indicator.alphaValue = isSelected ? 1 : 0
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(page)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyState()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyState()
    }
}

// MARK: - 词库词卡（悬停浮现操作按钮）

private final class VocabChipView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var normalBg: NSColor = .clear
    var hoverBg: NSColor = .clear
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.setAppearanceBackground(hoverBg)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.setAppearanceBackground(normalBg)
        onHoverChange?(false)
    }
}

// MARK: - 录音浮窗样式预览

/// 录音浮窗样式的「静态缩略图」：按 OverlayWindow 里 SiriCapsuleView 的真实配色，
/// 画一颗定格的小胶囊（不动画、不耗 CPU），让用户在设置里一眼看出两种样式的差别。
private final class OverlayStylePreview: NSView {
    private let mono: Bool
    init(mono: Bool) { self.mono = mono; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 148, height: 50) }

    override func draw(_ dirtyRect: NSRect) {
        let pillW: CGFloat = 116, pillH: CGFloat = 30
        let rect = NSRect(x: (bounds.width - pillW) / 2, y: (bounds.height - pillH) / 2,
                          width: pillW, height: pillH)
        let radius = pillH / 2
        let capsule = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        // 1. 胶囊填充：缩略图里两种都画成深色实心（墨黑更黑一点），方便在浅色卡片上辨识。
        (mono ? NSColor(white: 0.03, alpha: 1) : NSColor(white: 0.07, alpha: 1)).setFill()
        capsule.fill()

        // 2. 声波条：定格的钟形波形，裁剪在胶囊内（条数/间距/内缩与真实浮窗一致）。
        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()
        let barCount = 24
        let barSpacing: CGFloat = 1.5
        let barW = (pillW - 12) / CGFloat(barCount) - barSpacing
        let totalW = CGFloat(barCount) * (barW + barSpacing) - barSpacing
        let startX = rect.minX + (pillW - totalW) / 2
        let minH: CGFloat = 2.5
        let maxH = pillH - 9
        for i in 0..<barCount {
            let t = CGFloat(i) / CGFloat(barCount - 1)
            let bell = sin(CGFloat.pi * t)                          // 中间高、两边低
            let wobble = 0.55 + 0.45 * abs(sin(CGFloat(i) * 1.7))   // 固定起伏，制造波形感
            let h = max(minH, minH + (maxH - minH) * bell * wobble)
            let x = startX + CGFloat(i) * (barW + barSpacing)
            let barRect = NSRect(x: x, y: rect.midY - h / 2, width: barW, height: h)
            barColor(t).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // 3. 边框：彩色＝多色渐变环（近似浮窗的旋转 conic，静态）；墨黑＝淡白细边。
        if mono {
            NSColor(white: 1, alpha: 0.16).setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
        } else {
            drawColorfulRing(rect: rect, radius: radius)
        }
    }

    /// 波形条颜色：彩色＝粉→紫→蓝插值（同 SiriCapsuleView.barColorLeft/Mid/Right）；墨黑＝白。
    private func barColor(_ t: CGFloat) -> NSColor {
        if mono { return NSColor(white: 1, alpha: 0.92) }
        let pink = NSColor(red: 1.0, green: 0.25, blue: 0.50, alpha: 1)
        let purple = NSColor(red: 0.75, green: 0.20, blue: 0.90, alpha: 1)
        let blue = NSColor(red: 0.30, green: 0.35, blue: 1.00, alpha: 1)
        return t < 0.5 ? lerp(pink, purple, t * 2) : lerp(purple, blue, (t - 0.5) * 2)
    }

    private func lerp(_ a: NSColor, _ b: NSColor, _ k: CGFloat) -> NSColor {
        let a2 = a.usingColorSpace(.sRGB) ?? a
        let b2 = b.usingColorSpace(.sRGB) ?? b
        return NSColor(srgbRed: a2.redComponent + (b2.redComponent - a2.redComponent) * k,
                       green: a2.greenComponent + (b2.greenComponent - a2.greenComponent) * k,
                       blue: a2.blueComponent + (b2.blueComponent - a2.blueComponent) * k, alpha: 1)
    }

    /// 用一条 2px 环形路径填多色横向渐变，近似浮窗的彩色旋转边框（静态，是与 Mac 实时效果的已知偏差）。
    private func drawColorfulRing(rect: NSRect, radius: CGFloat) {
        let lw: CGFloat = 2
        let ring = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let hole = NSBezierPath(roundedRect: rect.insetBy(dx: lw, dy: lw),
                                xRadius: max(0, radius - lw), yRadius: max(0, radius - lw))
        ring.append(hole.reversed)
        ring.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        ring.addClip()
        let gradient = NSGradient(colors: [
            NSColor(red: 0.35, green: 0.45, blue: 1.00, alpha: 1),   // Blue
            NSColor(red: 0.60, green: 0.30, blue: 0.95, alpha: 1),   // Purple
            NSColor(red: 0.95, green: 0.35, blue: 0.60, alpha: 1),   // Pink
            NSColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 1),   // Orange
            NSColor(red: 0.30, green: 0.85, blue: 0.65, alpha: 1),   // Teal
            NSColor(red: 0.35, green: 0.45, blue: 1.00, alpha: 1),   // Blue
        ])
        gradient?.draw(in: bounds, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// 可点选的浮窗样式磁贴：上方静态预览 + 下方标题；选中时描强调色粗边。
private final class OverlayStyleTile: NSView {
    let mono: Bool
    private let theme: VPTheme
    var onSelect: (() -> Void)?

    init(mono: Bool, title: String, theme: VPTheme) {
        self.mono = mono
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.setAppearanceBackground(theme.cardAlt)
        layer?.borderWidth = 1
        layer?.setAppearanceBorder(theme.sep)

        let preview = OverlayStylePreview(mono: mono)
        preview.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = theme.text
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(preview)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            preview.centerXAnchor.constraint(equalTo: centerXAnchor),
            preview.widthAnchor.constraint(equalToConstant: 148),
            preview.heightAnchor.constraint(equalToConstant: 50),
            titleLabel.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        layer?.setAppearanceBorder((selected ? theme.accent : theme.sep))
        layer?.borderWidth = selected ? 2 : 1
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - 墨黑自绘按钮（无边框、圆角实心、文字色固定）

/// 用于定价页激活按钮：墨黑底白字、圆角无边框。
/// 关键点——激活流程会直接改 `.title`（"激活中…"/"激活"），普通 NSButton 那会丢掉颜色变黑底黑字看不见；
/// 这里重写 `title` 的赋值，始终把文字重新包成固定色，激活逻辑无需改动。
final class SolidLabelButton: NSButton {
    private let titleColor: NSColor

    init(title: String, color: NSColor, target: AnyObject?, action: Selector?) {
        self.titleColor = color
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 9
        font = .systemFont(ofSize: 13, weight: .semibold)
        self.title = title   // 触发 didSet，套上固定色
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var title: String {
        didSet {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: titleColor,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            ])
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 自绘下拉选择控件：外观与 VPSegmentedControl 同一套（浅灰轨道底 + 深边框 + 墨黑文字），
/// 点开用 NSMenu 呈现选项（当前项打勾、统一 13 号字）。用于选项多到横排放不下的场景（如润色模型）。
final class VPDropdown: NSControl {
    /// `warn` = 该项处于需要注意的状态（如免费额度已用完）：
    /// 收起时若选中项 warn，标题用 warnColor（红）提示"要动手"；菜单里则用弱化色，避免满屏红。
    struct Item { let value: String; let title: String; var warn: Bool = false }

    private let titleLabel: NSTextField
    private let menuTextColor: NSColor
    private let menuWarnColor: NSColor
    private let normalTextColor: NSColor
    private let selectedWarnColor: NSColor
    private var items: [Item]
    private(set) var selectedValue: String
    var onSelect: ((String) -> Void)?

    init(items: [Item], selectedValue: String,
         trackBg: NSColor, trackBorder: NSColor, textColor: NSColor, chevronColor: NSColor,
         warnColor: NSColor? = nil, mutedColor: NSColor? = nil) {
        self.items = items
        self.selectedValue = selectedValue
        self.menuTextColor = textColor
        self.menuWarnColor = mutedColor ?? chevronColor
        self.normalTextColor = textColor
        self.selectedWarnColor = warnColor ?? textColor
        let current = items.first { $0.value == selectedValue }
        self.titleLabel = NSTextField(labelWithString: current?.title ?? selectedValue)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.setAppearanceBackground(trackBg)
        layer?.borderWidth = 1
        layer?.setAppearanceBorder(trackBorder)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = (current?.warn == true) ? (warnColor ?? textColor) : textColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // 系统箭头图标（与原生控件同款），比文字符号更协调
        let chevron = NSImageView()
        if let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            chevron.image = img.withSymbolConfiguration(
                .init(pointSize: 9.5, weight: .semibold))
            chevron.contentTintColor = chevronColor
        }
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.minimumWidth = bounds.width
        for item in items {
            let mi = NSMenuItem(title: "", action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = item.value
            mi.attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [.font: NSFont.systemFont(ofSize: 13),
                             .foregroundColor: item.warn ? menuWarnColor : menuTextColor])
            mi.state = (item.value == selectedValue) ? .on : .off
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        selectedValue = value
        let picked = items.first { $0.value == value }
        titleLabel.stringValue = picked?.title ?? value
        titleLabel.textColor = (picked?.warn == true) ? selectedWarnColor : normalTextColor
        onSelect?(value)
    }
}

/// 全 App 统一的自绘按钮：固定高度 / 圆角 / 字重，带顺滑悬停反馈，替代散落各处的系统 .rounded 按钮。
/// 4 种样式：主操作实心(primary) / 次操作描边(secondary) / 危险操作(danger) / 图标(icon)。
/// 2 种尺寸：regular(高 30) / small(高 26，用于卡片内行内操作)。
final class VPButton: NSButton {
    enum Style { case primary, secondary, danger, icon }
    enum Size { case regular, small }

    private let style: Style
    private let size: Size
    private let titleColor: NSColor
    private let bgNormal: NSColor
    private let bgHover: NSColor
    private var hovering = false

    init(title: String, style: Style, size: Size = .regular, theme: VPTheme,
                     target: AnyObject?, action: Selector?) {
        self.style = style
        self.size = size
        switch style {
        case .primary:
            titleColor = theme.onAccent
            bgNormal = theme.accent
            bgHover = theme.accent.appearanceBlended(withFraction: 0.16, of: theme.onAccent)
        case .secondary:
            titleColor = theme.text
            bgNormal = theme.card
            bgHover = theme.cardAlt
        case .danger:
            titleColor = theme.danger
            bgNormal = theme.card
            bgHover = theme.danger.withAlphaComponent(0.07)
        case .icon:
            titleColor = theme.text3
            bgNormal = .clear
            bgHover = theme.cardAlt
        }
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = (style == .icon) ? 7 : 8
        switch style {
        case .secondary:
            layer?.borderWidth = 1
            layer?.setAppearanceBorder(theme.text.withAlphaComponent(0.14))
        case .danger:
            layer?.borderWidth = 1
            layer?.setAppearanceBorder(theme.danger.withAlphaComponent(0.32))
        default:
            layer?.borderWidth = 0
        }
        self.title = title   // 触发 didSet 套字色
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var fontSize: CGFloat { size == .regular ? 13 : 12 }
    private var fixedHeight: CGFloat { size == .regular ? 30 : 26 }
    private var hPadding: CGFloat { size == .regular ? 14 : 12 }

    override var title: String {
        didSet {
            let p = NSMutableParagraphStyle(); p.alignment = .center
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: titleColor,
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .paragraphStyle: p,
            ])
        }
    }

    override var intrinsicContentSize: NSSize {
        if style == .icon { return NSSize(width: fixedHeight, height: fixedHeight) }
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + hPadding * 2, height: fixedHeight)
    }

    private func updateBackground() {
        layer?.setAppearanceBackground((hovering ? bgHover : bgNormal))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateBackground() }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.45 }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 自绘滑动开关（iOS 风格）：开=近黑底圆钮在右，关=灰底圆钮在左；切换带平滑动画。
/// 用 `isOn` 读写状态、target/action 回调，替代系统蓝色复选框。
final class VPToggle: NSControl {
    private let trackOn: NSColor
    private let trackOff: NSColor
    private let trackLayer = CALayer()
    private let knobLayer = CALayer()

    private let trackW: CGFloat = 38
    private let trackH: CGFloat = 22
    private let knobD: CGFloat = 18
    private let inset: CGFloat = 2

    private(set) var isOn = false

    fileprivate init(theme: VPTheme, target: AnyObject?, action: Selector?) {
        trackOn = theme.accent
        trackOff = theme.text.withAlphaComponent(0.20)
        super.init(frame: NSRect(x: 0, y: 0, width: trackW, height: trackH))
        self.target = target
        self.action = action
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: trackW).isActive = true
        heightAnchor.constraint(equalToConstant: trackH).isActive = true

        trackLayer.frame = NSRect(x: 0, y: 0, width: trackW, height: trackH)
        trackLayer.cornerRadius = trackH / 2
        layer?.addSublayer(trackLayer)

        knobLayer.frame = NSRect(x: inset, y: inset, width: knobD, height: knobD)
        knobLayer.cornerRadius = knobD / 2
        knobLayer.setAppearanceBackground(theme.onAccent)   // 浅色下为白
        knobLayer.setAppearanceShadow(NSColor.black)
        knobLayer.shadowOpacity = 0.18
        knobLayer.shadowRadius = 1.5
        knobLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(knobLayer)

        render(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 设定开关状态（不触发 action）。animated=false 用于首次回显。
    func setOn(_ on: Bool, animated: Bool) {
        isOn = on
        render(animated: animated)
    }

    private func render(animated: Bool) {
        let knobX = isOn ? (trackW - knobD - inset) : inset
        if !animated {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        trackLayer.setAppearanceBackground((isOn ? trackOn : trackOff))
        knobLayer.frame = NSRect(x: knobX, y: inset, width: knobD, height: knobD)
        if !animated { CATransaction.commit() }
    }

    override func mouseDown(with event: NSEvent) { toggleByUser() }

    private func toggleByUser() {
        isOn.toggle()
        render(animated: true)
        sendAction(action, to: target)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // 辅助功能：读屏 / 自动化能读到开关状态并「按下」切换（原先只认鼠标，VoiceOver 用户点不了）
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .switch }
    override func accessibilityValue() -> Any? { NSNumber(value: isOn) }
    override func accessibilityPerformPress() -> Bool {
        toggleByUser()
        return true
    }
}

// MARK: - Window controller

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    enum Page: CaseIterable {
        case home
        case history
        case support
        case vocabulary
        case model
        case explore
        case settings
        case about

        var title: String {
            switch self {
            case .home: return "首页"
            case .history: return "历史记录"
            case .support: return "反馈"
            case .vocabulary: return "个人词库"
            case .model: return "模型"
            case .explore: return "探索"
            case .settings: return "设置"
            case .about: return "关于"
            }
        }

        var symbolName: String {
            switch self {
            case .home: return "house"
            case .history: return "clock.arrow.circlepath"
            case .support: return "bubble.left.and.bubble.right"
            case .vocabulary: return "book.closed"
            case .model: return "cpu"
            case .explore: return "sparkles"
            case .settings: return "gearshape"
            case .about: return "info.circle"
            }
        }
    }

    struct VocabularyEntry {
        var target: String
        var variants: [String]
        var category: String
        var source: String   // "auto" = 自动学习学到；其余视为手动添加

        var isAutoLearned: Bool { source == "auto" }
    }


    static var shared: SettingsWindowController?

    private weak var settingsDelegate: SettingsWindowDelegate?
    private let config = VoicePolishConfig.shared
    private let historyStore = PolishHistoryStore()
    private let audioStore = AudioClipStore.defaultStore()
    private var historyAudioPlayer: AVAudioPlayer?
    private var processingIndex: Int?               // 正在重新润色/转写的那条（行内转圈）
    private var historyUpdateSheet: NSWindow?       // 「更新历史」面板
    private weak var updateHistoryStack: NSStackView?
    private var historyProcessingLabel: String = ""
    private var cardActionContainers: [Int: NSStackView] = [:]  // 每条卡片右侧操作区，便于就地替换
    private var cardOutputLabels: [Int: NSTextField] = [:]      // 每条卡片正文 label，便于就地刷新
    private var cardViews: [Int: NSView] = [:]                  // 每条卡片整体视图，便于就地换整张卡（重转后不整页重建）
    private var selectedPage: Page = .home
    private var sidebarRows: [Page: SidebarRow] = [:]
    private let sidebarContainer = NSView()
    private let contentHost = NSView()
    private var historyEntries: [AIPolisher.PolishLog] = []
    private var vocabularyEntries: [VocabularyEntry] = []
    private weak var vocabQuickAddField: NSTextField?
    private var variantPopover: NSPopover?
    private weak var variantPopoverField: NSTextField?
    private var variantPopoverEntryIndex: Int = -1
    private var vocabFilter = 0   // 0=所有 1=自动学习 2=手动添加

    private var bigASRAPIKeyField: NSSecureTextField?
    private var bailianKeyField: NSSecureTextField?
    private var asrVersionControl: VPSegmentedControl?
    private var asrProviderControl: VPSegmentedControl?
    private var asrKeyContainer: NSStackView?
    private var asrGetKeyButton: NSButton?
    private var dashscopeAPIKeyField: NSSecureTextField?
    private var arkAPIKeyField: NSSecureTextField?
    private var polishProviderControl: VPSegmentedControl?
    private var polishKeyContainer: NSStackView?
    private var polishGetKeyButton: NSButton?
    private var asrTestResultLabel: NSTextField?
    private var polishTestResultLabel: NSTextField?
    private var licenseKeyField: NSTextField?       // 激活码输入框
    private var licenseStatusLabel: NSTextField?    // 激活操作结果提示
    private var healthExpandedOverride: Bool?       // nil=按状态默认（全绿折叠/有问题展开）
    private var asrTestButton: VPButton?
    private var polishTestButton: VPButton?
    private var autoLearnCheckbox: VPToggle?
    private var tapToggleCheckbox: VPToggle?
    private var outputLanguagePhraseFields: [String: NSTextField] = [:]
    private var outputLanguageAddNameField: NSTextField?
    private var outputLanguageAddPhrasesField: NSTextField?
    /// 「自定义触发词」是否展开（默认收起：普通用户只需要看到语言开关）
    private var outputLanguageAdvancedExpanded = false
    private var expandedExploreCards = Set<String>()
    private var launchAtLoginCheckbox: VPToggle?

    // History progressive loading
    private var allHistoryEntries: [AIPolisher.PolishLog] = []
    private var historyVisibleCount: Int = 0
    private let historyBatchSize: Int = 8
    private weak var historyContentStack: NSStackView?
    private weak var historyFooter: NSView?
    private var historyFileMtime: Date?

    // Page cache (lazy build, isHidden swap)
    private var cachedScrolls: [Page: NSScrollView] = [:]
    private var activeMicrophonePicker: MicrophonePickerSheet?

    private let theme = VPTheme.automatic
    // 这几处原是写死的浅灰：浅色值保持原样，只给深色配对应颜色
    private static let softFill = VPTheme.adaptive(light: NSColor(white: 0.94, alpha: 1), dark: VPTheme.dark.cardAlt)
    private static let meterTrack = VPTheme.adaptive(light: NSColor(white: 0.88, alpha: 1), dark: NSColor(white: 1, alpha: 0.14))
    private static let dropdownBorder = VPTheme.adaptive(light: NSColor.black.withAlphaComponent(0.16),
                                                         dark: NSColor.white.withAlphaComponent(0.16))

    static func show(delegate: SettingsWindowDelegate, initialPage: Page? = nil) {
        let controller: SettingsWindowController
        if let existing = shared {
            existing.settingsDelegate = delegate
            existing.reload()
            controller = existing
        } else {
            controller = SettingsWindowController(delegate: delegate)
            shared = controller
        }
        if let page = initialPage { controller.selectPage(page) }
        controller.clampWindowToMinSize()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 3.0 新手势演示没看完，就一直盖在正式页面上（关窗再开还在；看完才记为已看）
        if !WhatsNewGuide.hasSeen { controller.presentGuide(feature: .mouseHold, finishTitle: "开始使用") }
    }

    // MARK: - 新功能引导（盖在内容上）

    private var guideView: WhatsNewGuideView?

    /// 引导正盖在窗口上时返回窗口编号：鼠标长按说话的监听器平时忽略自家窗口，只对它放行（「试一试」输入框）
    var guideWindowNumber: Int? { guideView != nil ? window?.windowNumber : nil }

    /// 设置窗开着时返回窗口编号：里面的输入框（工单、词库、提示词……）也能按住说话；空白处不问 AI
    var dictationWindowNumber: Int? { window?.isVisible == true ? window?.windowNumber : nil }

    func presentGuide(feature: WhatsNewGuide.Feature, finishTitle: String, onlyThisFeature: Bool = false) {
        guard let cv = window?.contentView else { return }
        if guideView == nil {
            let view = WhatsNewGuideView(frame: cv.bounds)
            view.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(view, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
                view.topAnchor.constraint(equalTo: cv.topAnchor),
                view.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            ])
            view.onFinish = { [weak self] in self?.dismissGuide() }
            guideView = view
        }
        guideView?.present(feature: feature, finishTitle: finishTitle, onlyThisFeature: onlyThisFeature)
    }

    private func dismissGuide() {
        WhatsNewGuide.markSeen()
        guideView?.tearDown()
        guideView?.removeFromSuperview()
        guideView = nil
    }

    init(delegate: SettingsWindowDelegate) {
        self.settingsDelegate = delegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Typefree"  // 仅供系统辅助功能/窗口菜单，标题栏不显示（侧栏已有带 logo 的名字，避免重复）
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 1040, height: 600)   // 1040 以下统计大数字会被挤，锁住下限
        window.isReleasedWhenClosed = false
        window.contentView = AppearanceObservingView()  // 自定义根视图，用于捕获日/夜模式切换
        super.init(window: window)
        window.delegate = self
        applyMainWindowAppearance()   // 先定外观再建页面，颜色第一次就按对的深浅上
        if !window.setFrameAutosaveName("VoicePolishSettingsWindow") {
            window.center()
        }
        clampWindowToMinSize()
        // macOS 26 上自定义 contentView 与窗口之间的宽度跟随（autoresizing 桥接）会丢失，
        // 布局引擎转而把 contentView 连同窗口压到内容的最小宽度（首页恰好 629，窗口随之变窄）。
        // 显式把 contentView 宽度钉回窗口内容区，窗口尺寸恢复由用户/frame 恢复控制。
        if let cv = window.contentView, let guide = window.contentLayoutGuide as? NSLayoutGuide {
            cv.widthAnchor.constraint(equalTo: guide.widthAnchor).isActive = true
        }
        setupShell()
        loadVocabularyEntries()
        rebuildSidebar()
        selectPage(.home)
        lastEnvironmentSnapshot = currentEnvironmentSnapshot()   // 首页刚按当前状态建好，以此为基准
        refreshTrialStatusIfNeeded()
        // 系统切换外观只刷新颜色，保留输入框、滚动位置和展开状态。
        (window.contentView as? AppearanceObservingView)?.onAppearanceChange = { [weak self] in
            self?.applyTheme()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(termCorrectionsDidChangeExternally),
            name: .voicePolishTermCorrectionsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(microphoneSelectionDidChange),
            name: .voicePolishMicrophoneSelectionDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(microphoneSelectionDidChange),
            name: .voicePolishMicrophoneListDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyDidChange),
            name: .voicePolishHotkeyDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateStateDidChange),
            name: .typefreeUpdateStateDidChange,
            object: nil
        )
        // 用户去系统设置开权限再切回来时，健康卡/权限行的状态要跟着变
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(permissionsMayHaveChanged),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(permissionsMayHaveChanged),
            name: .voicePolishAccessibilityGranted,
            object: nil
        )
        // 试用状态：每次切回 App 向服务器刷新一次（原先放在侧栏渲染里，会被反复触发）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        // 会员状态（开通 / 续费 / 到期 / 创世标识）变化：刷新侧栏与关于页
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(membershipDidChange),
            name: LicenseManager.membershipDidChangeNotification,
            object: nil
        )
        // 「设置 → 外观」切换，或系统深浅切换（含「自动」模式天黑天亮）：重新套外观
        MainWindowAppearance.observeSystemChanges()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSettingDidChange),
            name: MainWindowAppearance.didChangeNotification,
            object: nil
        )
    }

    // MARK: - 外观（只管主窗口）

    /// 按「设置 → 外观」给主窗口设外观。只设这一个窗口（它弹出的子窗口、菜单会自动跟随），
    /// App 其余部分仍锁浅色。外观变化会触发 AppearanceObservingView → applyTheme 刷新全部颜色。
    private func applyMainWindowAppearance() {
        guard let window else { return }
        let appearance = MainWindowAppearance.resolve()
        MainWindowAppearance.applied = appearance
        guard window.appearance?.name != appearance.name else { return }
        window.appearance = appearance
        applyTheme()
    }

    @objc private func appearanceSettingDidChange() {
        applyMainWindowAppearance()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        applyMainWindowAppearance()   // 兜底：万一漏了切换通知，用户回到窗口时补上
    }

    @objc private func appDidBecomeActive() {
        refreshTrialStatusIfNeeded()
    }

    @objc private func membershipDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildSidebar()
            self?.invalidate(.about)
        }
    }

    /// 试用中且未激活时向服务器刷新一次；成功后重绘侧栏让「今日用量 / 剩余天数」趋新。
    private func refreshTrialStatusIfNeeded() {
        guard TrialManager.shared.isInTrial, !LicenseManager.shared.isActivated else { return }
        TrialManager.shared.refreshFromServer { [weak self] ok in
            guard ok else { return }
            self?.rebuildSidebar()   // completion 已在主线程回调
        }
    }

    @objc private func updateStateDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildSidebar()
            self?.invalidate(.about)
        }
    }

    /// 首页 / 设置页里「App 不在前台时也会自己变」的东西：两个权限、登录项、输入统计。
    /// 原先每次切回 App 都无条件重建这两页，而绝大多数切回来时这些值一个都没变，
    /// 重建出来的页面和原来一模一样——纯属白做，偏偏这一步在 macOS 15 上崩过
    /// （工单 #1005 的崩溃报告停在「重建首页 → 建换行文字标签」，#1007 的日志同一形状）。
    /// 所以记一份上次重建时的值，真变了才重建；变了那条路和原来完全一样，用户看不出差别。
    private struct EnvironmentSnapshot: Equatable {
        var accessibilityTrusted: Bool
        var microphoneAuthorization: Int
        var launchAtLogin: Bool
        var todayChars: Int
        var todaySessions: Int
        var allTimeChars: Int
    }

    private var lastEnvironmentSnapshot: EnvironmentSnapshot?

    private func currentEnvironmentSnapshot() -> EnvironmentSnapshot {
        let today = InputStats.shared.today()
        return EnvironmentSnapshot(
            accessibilityTrusted: AXIsProcessTrusted(),
            microphoneAuthorization: AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            launchAtLogin: LaunchAtLogin.isEnabled,
            todayChars: today.charCount,
            todaySessions: today.sessionCount,
            allTimeChars: InputStats.shared.allTimeTotal().chars
        )
    }

    @objc private func permissionsMayHaveChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let snapshot = self.currentEnvironmentSnapshot()
            guard snapshot != self.lastEnvironmentSnapshot else { return }   // 什么都没变：不重建
            self.lastEnvironmentSnapshot = snapshot
            self.settingsDelegate?.debugLog("Settings: 权限/统计有变化，重建首页与设置页")
            self.invalidate(.home, .settings)
        }
    }

    @objc private func microphoneSelectionDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.invalidate(.settings, .home)
        }
    }

    @objc private func hotkeyDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.invalidate(.home)
        }
    }

    @objc private func termCorrectionsDidChangeExternally() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.loadVocabularyEntries()
            self.rebuildSidebar()
            self.invalidate(.vocabulary)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        Self.shared = nil
    }

    /// 窗口可能被首次布局/frame 恢复等程序化路径压到 minSize 以下（minSize 只挡手动拖拽），统一补回下限
    func clampWindowToMinSize() {
        guard let window else { return }
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            var frame = window.frame
            frame.size.width = max(frame.size.width, window.minSize.width)
            frame.size.height = max(frame.size.height, window.minSize.height)
            window.setFrame(frame, display: true)
        }
    }


    // MARK: - Shell

    private func setupShell() {
        guard let cv = window?.contentView else { return }
        cv.wantsLayer = true
        cv.layer?.setAppearanceBackground(theme.bg)

        sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.wantsLayer = true
        cv.addSubview(sidebarContainer)

        let divider = NSBox()
        divider.boxType = .custom
        divider.fillColor = theme.sep
        divider.borderWidth = 0
        divider.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(divider)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.wantsLayer = true
        cv.addSubview(contentHost)

        NSLayoutConstraint.activate([
            sidebarContainer.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            sidebarContainer.topAnchor.constraint(equalTo: cv.topAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            sidebarContainer.widthAnchor.constraint(equalToConstant: 178),
            divider.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            divider.topAnchor.constraint(equalTo: cv.topAnchor),
            divider.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            contentHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: cv.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        applyTheme()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        applyTheme()
    }

    private func applyTheme() {
        guard let cv = window?.contentView else { return }
        cv.layer?.setAppearanceBackground(theme.bg)
        sidebarContainer.layer?.setAppearanceBackground(theme.sidebarBg)
        contentHost.layer?.setAppearanceBackground(theme.bg)
        window?.backgroundColor = theme.bg
        (cv as? AppearanceObservingView)?.refreshAppearance()
    }

    // MARK: - Sidebar

    private func rebuildSidebar() {
        sidebarContainer.subviews.forEach { $0.removeFromSuperview() }
        sidebarContainer.layer?.setAppearanceBackground(theme.sidebarBg)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(stack)

        // Brand
        let brand = makeBrandHeader()
        stack.addArrangedSubview(brand)
        brand.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(14, after: brand)

        // Groups
        let historyCount = quickHistoryLineCount()
        let vocabCount = vocabularyEntries.count

        let unread = SupportChatService.shared.unreadCount
        let groups: [(String?, [(Page, String?)])] = [
            ("工作台", [(.home, nil), (.history, historyCount > 0 ? "\(historyCount)" : nil)]),
            ("配置", [(.vocabulary, vocabCount > 0 ? "\(vocabCount)" : nil), (.model, nil), (.explore, nil), (.settings, nil),
                     (.support, unread > 0 ? "\(unread) 条新回复" : nil)]),
            (nil, [(.about, nil)]),
        ]

        sidebarRows.removeAll()
        for (gtitle, items) in groups {
            if let gt = gtitle {
                stack.addArrangedSubview(makeGroupTitle(gt))
                stack.arrangedSubviews.last!.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            for (page, count) in items {
                let row = SidebarRow(page: page, count: count)
                row.apply(theme: theme)
                row.isSelected = (page == selectedPage)
                row.onClick = { [weak self] in self?.selectPage($0) }
                sidebarRows[page] = row
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        // spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spacer)
        spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true

        // 底部方案卡：未激活 → 试用 / 试用到期 / 自带 Key；会员 → 只在快到期或已到期时提醒续费，平时不打扰
        let planCard: NSView? = LicenseManager.shared.isActivated ? makeSidebarMemberRenewalCard() : makeSidebarUpgradeButton()
        if let upgrade = planCard {
            stack.addArrangedSubview(upgrade)
            upgrade.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(10, after: upgrade)
        }

        // bottom status
        let bottom = makeSidebarStatus()
        stack.addArrangedSubview(bottom)
        bottom.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: sidebarContainer.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor, constant: -10),
        ])
    }

    private func makeBrandHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        // 创世用户（3.0 前的付费/受赠用户，Ray 2026-09-14）：logo 放大到 40，右侧两行——名字 + 版本号、创世用户标签——
        // 整块与 logo 上下对齐。
        //
        // ⚠ 宽度是这里唯一的难点，别再凭感觉调（2026-09-18 重量过）：侧栏 178，去掉两侧 8 的留白、
        // logo 10+40 和 10 的间距、右侧 4 的余量，两行真正可用 98 点。实测文字宽度：
        // 名字 60.1、版本号 26.8、创世用户胶囊 53.8、NEW 徽章 34.1（>=31 的宽度下限 + 左右各 6）。
        // 旧版右侧留 8（可用 94），第一行 92.9、第二行 93.9，全是零点几点的余量——只要字体度量差一丝，
        // 系统就压「创世用户」那个标签，它折成两行、胶囊变高往上顶，于是名字被盖、看起来像"变形"（Ray 截图）。
        // 现在：有新版本时用 8 点的小红点代替 NEW 徽章（第二行降到 67.8），名字和标签都禁止折行。
        let isGenesis = LicenseManager.shared.isGenesis
        let logo = makeWaveformMark(box: isGenesis ? 40 : 28, corner: isGenesis ? 11 : 8, boxColor: theme.accent, waveColor: theme.onAccent)

        let title = NSTextField(labelWithString: "Typefree")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = theme.text
        title.translatesAutoresizingMaskIntoConstraints = false
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.required, for: .horizontal)   // 名字永远完整，不折不缩

        // 版本号：常驻显示，点它看「更新历史」（用户想知道"我在用哪一版、都更新了什么"）
        let version = NSTextField(labelWithString: Bundle.main.appVersionString)
        version.font = .systemFont(ofSize: 11, weight: .medium)
        version.textColor = theme.text3
        version.translatesAutoresizingMaskIntoConstraints = false
        version.toolTip = "查看更新历史"
        version.maximumNumberOfLines = 1
        version.lineBreakMode = .byTruncatingTail
        version.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)   // 真放不下时，让它先截断

        header.addSubview(logo)
        header.addSubview(title)
        header.addSubview(version)

        var genesisTag: NSView?
        if isGenesis {
            let tag = makeTag("创世用户", bg: Self.softFill, fg: theme.text, size: 10)
            tag.toolTip = "3.0 之前就支持 Typefree 的用户，谢谢你一路同行"
            header.addSubview(tag)
            genesisTag = tag
        }

        var trailingView: NSView = version
        if let updateInfo = settingsDelegate?.pendingUpdateInfo(), updateInfo.errorMessage == nil {
            // 小红点代替 NEW 徽章：见上面的宽度账。非创世用户那一行（名字+版本号+NEW＝128）同样放不下，
            // 所以两种排版都用红点；整块 header 仍可点，提示文案不变。
            let badge = makeNewDot()
            header.addSubview(badge)
            // 创世用户排版里，NEW 放到第二行标签后面（第一行放不下）
            let anchorView: NSView = genesisTag ?? version
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: anchorView.trailingAnchor, constant: 6),
                badge.centerYAnchor.constraint(equalTo: (genesisTag ?? title).centerYAnchor),
            ])
            trailingView = badge
            header.toolTip = "查看新版本"
            header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(updateBadgeTapped)))
        } else {
            // 没有待装新版时，整块 header 点击 = 看更新历史（点 logo/名字/版本号都行，命中区域更大）
            header.toolTip = "查看更新历史"
            header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showUpdateHistory)))
        }

        if let tag = genesisTag {
            NSLayoutConstraint.activate([
                logo.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
                logo.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                // 名字字形顶端贴 logo 上沿（14pt 字的大写高度起点在文字框下方约 4 点），标签底边贴 logo 下沿
                title.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
                title.topAnchor.constraint(equalTo: logo.topAnchor, constant: -4),
                version.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
                version.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
                tag.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                tag.bottomAnchor.constraint(equalTo: logo.bottomAnchor),
                trailingView.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -4),
                header.heightAnchor.constraint(equalToConstant: 58),
            ])
        } else {
            NSLayoutConstraint.activate([
                logo.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
                logo.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                title.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 9),
                title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                version.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 7),
                version.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
                trailingView.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -4),
                header.heightAnchor.constraint(equalToConstant: 42),
            ])
        }
        return header
    }

    // MARK: - 更新历史

    /// 「更新历史」面板：从 appcast 拉取各版本的发布日期与更新说明。
    /// 数据源就是 Sparkle 用的那份 appcast，不额外维护更新日志文件。
    @objc private func showUpdateHistory() {
        guard let window = window else { return }
        let panel = makeUpdateHistoryPanel()
        historyUpdateSheet = panel
        window.beginSheet(panel) { [weak self] _ in self?.historyUpdateSheet = nil }
        loadUpdateHistory()
    }

    private func makeUpdateHistoryPanel() -> NSWindow {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                             styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "更新历史"

        let root = NSView()
        root.wantsLayer = true
        root.layer?.setAppearanceBackground(theme.bg)

        let heading = label("更新历史", size: 17, weight: .semibold, color: theme.text)
        let sub = label("当前版本 \(Bundle.main.appVersionString)", size: 12, weight: .regular, color: theme.text3)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22                 // 版本块之间（分隔线两侧各占一半）
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        updateHistoryStack = stack

        let close = VPButton(title: "关闭", style: .secondary, size: .regular,
                             theme: theme, target: self, action: #selector(closeUpdateHistory))

        for v in [heading, sub, scroll, close] { root.addSubview(v) }
        [heading, sub, close].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            sub.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            sub.leadingAnchor.constraint(equalTo: heading.leadingAnchor),

            // 宽度钉在滚动区上（而不是 contentView 上）：给 window.contentView 加尺寸约束
            // 会和系统的 autoresizing 冲突而被丢弃，面板就会被长段落文字的固有宽度撑爆。
            scroll.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 22),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            scroll.widthAnchor.constraint(equalToConstant: updateHistoryScrollWidth),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -18),

            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
        panel.contentView = root
        panel.setContentSize(NSSize(width: updateHistoryScrollWidth + 60, height: 560))
        return panel
    }

    /// 更新历史面板的滚动区宽度；面板总宽 = 它 + 左右各 24 边距。
    private var updateHistoryScrollWidth: CGFloat { 540 }

    @objc private func closeUpdateHistory() {
        guard let sheet = historyUpdateSheet else { return }
        window?.endSheet(sheet)
    }

    private func loadUpdateHistory() {
        setUpdateHistoryMessage("正在获取…")
        guard let url = URL(string: AppLinks.appcastURL) else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData   // 刚发的版本要能立刻看到
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let xml = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let entries = AppcastParser.parse(xml)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if entries.isEmpty {
                    self.setUpdateHistoryMessage("暂时获取不到更新历史，请检查网络后重试。")
                } else {
                    self.renderUpdateHistory(entries)
                }
            }
        }.resume()
    }

    private func setUpdateHistoryMessage(_ text: String) {
        guard let stack = updateHistoryStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let l = label(text, size: 12.5, weight: .regular, color: theme.text3)
        l.maximumNumberOfLines = 0
        stack.addArrangedSubview(l)
    }

    /// 正文折行宽度：滚动区宽度再留出竖向滚动条的位置。
    private var updateHistoryContentWidth: CGFloat { updateHistoryScrollWidth - 16 }

    private func renderUpdateHistory(_ entries: [AppcastEntry]) {
        guard let stack = updateHistoryStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let contentWidth = updateHistoryContentWidth

        let df = DateFormatter()
        df.dateFormat = "yyyy年M月d日"
        df.locale = Locale(identifier: "zh_CN")
        let current = Bundle.main.appVersionString

        for (idx, e) in entries.enumerated() {
            // 版本之间加一条细分隔线，避免整页糊成一片
            if idx > 0 {
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.setAppearanceBackground(theme.sep)
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                NSLayoutConstraint.activate([
                    sep.heightAnchor.constraint(equalToConstant: 1),
                    sep.widthAnchor.constraint(equalTo: stack.widthAnchor),
                ])
            }

            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 10                       // 版本号与正文之间留出呼吸
            row.translatesAutoresizingMaskIntoConstraints = false

            let head = NSStackView()
            head.orientation = .horizontal
            head.alignment = .centerY
            head.spacing = 10
            head.addArrangedSubview(label(e.version, size: 16, weight: .semibold, color: theme.text))
            if let d = e.pubDate {
                head.addArrangedSubview(label(df.string(from: d), size: 11.5, weight: .regular, color: theme.text3))
            }
            if e.version == current {
                head.addArrangedSubview(makeSoftTag("当前版本"))
            }
            row.addArrangedSubview(head)

            let body = NSTextField(labelWithString: "")
            body.maximumNumberOfLines = 0
            body.lineBreakMode = .byWordWrapping
            body.preferredMaxLayoutWidth = contentWidth        // 有它才知道在哪儿折行
            body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            body.setContentHuggingPriority(.defaultLow, for: .horizontal)
            body.translatesAutoresizingMaskIntoConstraints = false
            if e.notesHTML.isEmpty {
                body.stringValue = "这一版没有留下更新说明。"
                body.font = .systemFont(ofSize: 12.5)
                body.textColor = theme.text3
            } else if let attr = Self.attributedNotes(fromHTML: e.notesHTML,
                                                      bodyColor: theme.text2, headingColor: theme.text) {
                body.attributedStringValue = attr
            } else {
                body.stringValue = e.notesHTML
                body.font = .systemFont(ofSize: 12.5)
                body.textColor = theme.text2
            }
            row.addArrangedSubview(body)

            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            body.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
    }

    /// 更新说明是 HTML（appcast 的 CDATA），交给 ReleaseNotesRenderer 渲染成富文本（与「发现新版本」弹窗共用同一套排版）；
    /// 失败则由调用方回落纯文本。
    private static func attributedNotes(fromHTML html: String,
                                        bodyColor: NSColor, headingColor: NSColor) -> NSAttributedString? {
        guard let rendered = ReleaseNotesRenderer.attributed(fromHTML: html, bodyColor: bodyColor,
                                                             headingColor: headingColor) else { return nil }
        // CSS 里的颜色是按当时的浅色写死的；换回主题动态色，主窗口深色时也看得清（浅色下解析出来还是原来的颜色）。
        // 只在主窗口这里换，「发现新版本」弹窗那条路不动。
        let notes = NSMutableAttributedString(attributedString: rendered)
        let headingHex = headingColor.cssHex
        notes.enumerateAttributes(in: NSRange(location: 0, length: notes.length)) { attributes, range, _ in
            guard attributes[.link] == nil, let imported = attributes[.foregroundColor] as? NSColor else { return }
            notes.addAttribute(.foregroundColor, value: imported.cssHex == headingHex ? headingColor : bodyColor, range: range)
        }
        return notes
    }

    /// 侧栏顶部「有新版本」提示：8 点小红点。
    /// 原来是 NEW 文字徽章（34 点宽），侧栏那两行只有 98 点可用，加上它必挤——见 makeBrandHeader 里的宽度账。
    private func makeNewDot() -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = 4
        dot.layer?.setAppearanceBackground(NSColor(hex: 0xE5484D))
        dot.toolTip = "有新版本，点击查看"
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        return dot
    }

    private func makeNewBadge() -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.layer?.setAppearanceBackground(NSColor(hex: 0xE5484D))
        badge.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "NEW")
        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(label)

        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 16),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 31),
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: badge.centerYAnchor, constant: -0.5),
        ])
        return badge
    }

    @objc private func updateBadgeTapped() {
        settingsDelegate?.showUpdateDetails(nil)
    }

    private func makeGroupTitle(_ text: String) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 11, weight: .medium)
        lbl.textColor = theme.text3
        lbl.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12),
            lbl.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -12),
            lbl.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 10),
            lbl.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
        ])
        return wrap
    }

    private func makeSidebarStatus() -> NSView {
        let bottom = NSView()
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox()
        line.boxType = .custom
        line.fillColor = theme.sep
        line.borderWidth = 0
        line.translatesAutoresizingMaskIntoConstraints = false

        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.setAppearanceBackground((micOK ? theme.ok : theme.text3))
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: micOK ? "麦克风就绪" : "未授权麦克风")
        label.font = .systemFont(ofSize: 11)
        label.textColor = theme.text3
        label.translatesAutoresizingMaskIntoConstraints = false

        bottom.addSubview(line)
        bottom.addSubview(dot)
        bottom.addSubview(label)

        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -12),
            line.topAnchor.constraint(equalTo: bottom.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            dot.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: bottom.centerYAnchor, constant: 6),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 38),
        ])
        return bottom
    }

    // MARK: - Page switching

    private func selectPage(_ page: Page) {
        // Auto-invalidate history if log file changed since last build
        if page == .history,
           let attrs = try? FileManager.default.attributesOfItem(atPath: historyStore.fileURL.path),
           let mtime = attrs[.modificationDate] as? Date,
           mtime != historyFileMtime {
            historyFileMtime = mtime
            invalidate(.history)
        }

        selectedPage = page
        for (k, row) in sidebarRows {
            row.isSelected = (k == page)
        }

        // Lazy build on first entry
        if cachedScrolls[page] == nil {
            let scroll = buildScroll(for: page)
            cachedScrolls[page] = scroll
            contentHost.addSubview(scroll)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: contentHost.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            ])
        }

        // Toggle visibility instead of destroy/rebuild
        for (k, scroll) in cachedScrolls {
            scroll.isHidden = (k != page)
        }

        if page == .support { supportChatView?.pageDidAppear() }
    }

    // MARK: - Page: Support（反馈工单）

    private weak var supportChatView: SupportChatView?
    private var supportObserver: NSObjectProtocol?

    /// 反馈页不走通用的「内容多长页面多长」滚动：列表/对话区自己滚、输入区钉在底部，整页正好填满窗口。
    /// 页头由 SupportChatView 自己画（列表页带「提交工单」按钮，详情页是工单标题）。
    private func buildSupportScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        let chat = SupportChatView(theme: theme, context: SupportChatView.Context(
            latestTranscript: { [weak self] in
                guard let self, let e = self.historyStore.load(limit: 1).first else { return nil }
                let audio = e.audioFile.flatMap { self.audioStore.loadData(fileName: $0) }
                return (asr: e.asr, output: e.output, audio: audio)
            },
            recentApp: { [weak self] in self?.settingsDelegate?.recentTargetAppName() },
            logTail: { [weak self] in self?.settingsDelegate?.debugLogTail() ?? "" }
        ))
        supportChatView = chat
        SupportChatView.log = { [weak self] in self?.settingsDelegate?.debugLog($0) }
        doc.addSubview(chat)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            chat.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 56),
            // 右边多给一条滚动条空隙：内容仍与其它页面一样离右边 56，浮着的滚动条落在空隙里
            chat.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -56 + SupportChatView.scrollerGutter),
            chat.topAnchor.constraint(equalTo: doc.topAnchor, constant: 36),
            chat.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -32),
            chat.widthAnchor.constraint(lessThanOrEqualToConstant: 880 + SupportChatView.scrollerGutter),
        ])
        if supportObserver == nil {
            supportObserver = NotificationCenter.default.addObserver(forName: SupportChatService.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.rebuildSidebar()   // 角标跟着未读数变
            }
        }
        return scroll
    }

    private func buildScroll(for page: Page) -> NSScrollView {
        if page == .support { return buildSupportScroll() }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = false // 隐藏主页面滚动条，仍可用滚轮和触控板滚动。
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        // 窗口是透明全尺寸标题栏，NSScrollView 会自动再加一段标题栏高度的顶部留白（约 38pt），
        // 叠上下面的 40 就成了近 80pt 的空档，页面看着头重脚轻。关掉自动留白，顶部只留和侧栏 logo 对齐的一段。
        scroll.automaticallyAdjustsContentInsets = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        switch page {
        case .home: buildHome(into: stack)
        case .history: buildHistory(into: stack)
        case .vocabulary: buildVocab(into: stack)
        case .model: buildModel(into: stack)
        case .explore: buildExplore(into: stack)
        case .settings: buildSettings(into: stack)
        case .about: buildAbout(into: stack)
        case .support: break   // 见 buildSupportScroll
        }

        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        scroll.documentView = doc

        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 56),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -56),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 36),   // 与侧栏品牌头（32）大致齐平
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -48),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 880),
        ])

        // Only history page needs lazy-load scroll listener
        if page == .history {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollDidScroll(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scroll.contentView
            )
        }

        return scroll
    }

    /// Drop the cached view for the given pages so they rebuild on next entry.
    /// If the currently-visible page is invalidated, rebuild it immediately.
    private func invalidate(_ pages: Page...) {
        for p in pages {
            if let scroll = cachedScrolls.removeValue(forKey: p) {
                if p == .history {
                    NotificationCenter.default.removeObserver(
                        self,
                        name: NSView.boundsDidChangeNotification,
                        object: scroll.contentView
                    )
                    historyContentStack = nil
                    historyFooter = nil
                }
                scroll.removeFromSuperview()
            }
        }
        if pages.contains(selectedPage) {
            selectPage(selectedPage)
        }
    }

    /// Wipe all caches (e.g. on theme change) and rebuild the visible page.
    private func reload() {
        for (_, scroll) in cachedScrolls {
            scroll.removeFromSuperview()
        }
        cachedScrolls.removeAll()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        historyContentStack = nil
        historyFooter = nil
        contentHost.layer?.setAppearanceBackground(theme.bg)
        selectPage(selectedPage)
    }

    @objc private func scrollDidScroll(_ note: Notification) {
        guard selectedPage == .history else { return }
        guard historyVisibleCount < allHistoryEntries.count else { return }
        guard let clip = note.object as? NSClipView else { return }
        let docHeight = clip.documentRect.height
        let viewportBottom = clip.bounds.origin.y + clip.bounds.height
        let distanceToBottom = docHeight - viewportBottom
        if distanceToBottom < 240 {
            appendNextHistoryBatch()
        }
    }

    // MARK: - Page: Home

    private func buildHome(into stack: NSStackView) {
        stack.addArrangedSubview(pageHeader(eyebrow: "TYPEFREE / 首页", title: "首页",
                                             sub: "自然说话，清楚输入。这是你的语音工作台。"))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // Hero
        let hero = makeHomeHero()
        stack.addArrangedSubview(hero)
        stack.setCustomSpacing(16, after: hero)

        // Stats
        let stats = InputStats.shared
        let today = stats.today()
        let week = stats.currentWeekTotal()
        let month = stats.currentMonthTotal()
        let allTime = stats.allTimeTotal()
        let statsGrid = makeStatsGrid([
            ("今日", today.charCount, "\(today.sessionCount) 次会话"),
            ("本周", week.chars, "\(week.sessions) 次"),
            ("本月", month.chars, "\(month.sessions) 次"),
            ("累计", allTime.chars, "\(allTime.sessions) 次"),
        ])
        stack.addArrangedSubview(statsGrid)
        stack.setCustomSpacing(24, after: statsGrid)

        // 近 6 周一行圆点 + 连续天数（Ray 2026-09-15 选的方案三；不带标题）
        let rhythmCard = makeRhythmCard(stats: stats)
        stack.addArrangedSubview(rhythmCard)
        stack.setCustomSpacing(24, after: rhythmCard)

        let healthTitle = sectionTitle("配置健康")
        stack.addArrangedSubview(healthTitle)
        stack.setCustomSpacing(8, after: healthTitle)
        let healthCard = makeHealthCard()
        stack.addArrangedSubview(healthCard)
        // 反馈搬到侧栏「反馈」页（对话式，能附截图、能收到回复）
    }

    /// 「节律」卡片：一行墨点（RhythmStripView）+ 一排小标签（连续 / 最长 / 活跃天数 / 最常周几）
    private func makeRhythmCard(stats: InputStats) -> NSView {
        let card = makeCard()
        let rhythm = ActivityRhythm.compute(records: stats.allDailyRecords())

        let strip = RhythmStripView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.apply(days: rhythm.days, theme: theme)

        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = 6
        let okTag = makeTag("已连续 \(rhythm.currentStreak) 天", bg: RhythmStripView.accent.withAlphaComponent(0.12), fg: RhythmStripView.accent)
        chips.addArrangedSubview(okTag)
        chips.addArrangedSubview(makeSoftTag("最长连续 \(rhythm.bestStreak) 天"))
        chips.addArrangedSubview(makeSoftTag("活跃 \(rhythm.activeDays) 天"))
        if let w = rhythm.busiestWeekday {
            chips.addArrangedSubview(makeSoftTag("最常在\(ActivityRhythm.weekdayNames[w])用"))
        }

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        column.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)
        column.addArrangedSubview(strip)
        column.addArrangedSubview(chips)
        mount(column, in: card)
        strip.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        return card
    }

    private func makeHomeHero() -> NSView {
        let card = makeCard()

        let tapToggleEnabled = RecordingHotkeyBehavior.isTapToggleEnabled
        let shortcut = RecordingHotkeyShortcut.current
        let titlePrefix = label(tapToggleEnabled ? "长按或单击" : "长按",
                                size: 24, weight: .semibold, color: theme.text)
        let titleSuffix = label("开始说话", size: 24, weight: .semibold, color: theme.text)
        let hotkeyPicker = makeHotkeyPickerButton()

        titlePrefix.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleSuffix.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.addArrangedSubview(titlePrefix)
        titleRow.addArrangedSubview(hotkeyPicker)
        titleRow.addArrangedSubview(titleSuffix)
        titleRow.setContentCompressionResistancePriority(.required, for: .horizontal)

        let descText = tapToggleEnabled
            ? "\(shortcut.displayName) 长按时松开结束；单击时再次单击结束。结束后自动转写并粘贴。"
            : "\(shortcut.displayName) 松开后自动转写，并粘贴到当前光标位置。"
        let desc = label(descText,
                          size: 13, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0
        desc.lineBreakMode = .byWordWrapping

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 6
        leftStack.addArrangedSubview(titleRow)
        leftStack.addArrangedSubview(desc)

        // 三个鼠标 / 口令用法一眼看到（3.0 新功能），点哪个看哪个的演示
        let gestures = NSStackView()
        gestures.orientation = .horizontal
        gestures.alignment = .centerY
        gestures.spacing = 28
        gestures.addArrangedSubview(makeGestureHint(key: "输入框里按住鼠标", label: "说话", feature: .mouseHold))
        gestures.addArrangedSubview(makeGestureHint(key: "空白处按住鼠标", label: "问 AI", feature: .ask))
        gestures.addArrangedSubview(makeGestureHint(key: "结尾说「用英文」", label: "翻译", feature: .translation))

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.distribution = .fill
        main.spacing = 14
        main.edgeInsets = NSEdgeInsets(top: 18, left: 28, bottom: 16, right: 28)
        main.addArrangedSubview(leftStack)
        let rule = makeHairline(insetH: 0)
        main.addArrangedSubview(rule)
        main.addArrangedSubview(gestures)
        mount(main, in: card)
        rule.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -56).isActive = true
        return card
    }

    /// 首页快捷用法：键帽样式的动作 + 结果；整块可点，打开该功能的演示
    private func makeGestureHint(key: String, label text: String, feature: WhatsNewGuide.Feature) -> NSView {
        let cap = NSView()
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 6
        cap.layer?.borderWidth = 1
        cap.layer?.setAppearanceBorder(theme.sep)
        cap.layer?.setAppearanceBackground(theme.cardAlt)
        let capLabel = label(key, size: 12, weight: .medium, color: theme.text)
        capLabel.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(capLabel)
        NSLayoutConstraint.activate([
            capLabel.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 9),
            capLabel.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -9),
            capLabel.topAnchor.constraint(equalTo: cap.topAnchor, constant: 4),
            capLabel.bottomAnchor.constraint(equalTo: cap.bottomAnchor, constant: -4),
        ])
        let arrow = label("→", size: 12, weight: .regular, color: theme.text3)
        let result = label(text, size: 13, weight: .medium, color: theme.text2)
        let row = NSStackView(views: [cap, arrow, result])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.toolTip = "看演示"
        let click = NSClickGestureRecognizer(target: self, action: #selector(gestureHintTapped(_:)))
        row.addGestureRecognizer(click)
        row.identifier = NSUserInterfaceItemIdentifier("gesture-\(feature.rawValue)")
        return row
    }

    @objc private func gestureHintTapped(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue, let raw = Int(id.replacingOccurrences(of: "gesture-", with: "")),
              let feature = WhatsNewGuide.Feature(rawValue: raw) else { return }
        presentGuide(feature: feature, finishTitle: "完成", onlyThisFeature: true)
    }

    private func makeHotkeyPickerButton() -> NSButton {
        let button = NSButton(title: "\(RecordingHotkeyShortcut.current.displayName)  ▾",
                              target: self,
                              action: #selector(showHotkeyMenu(_:)))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.font = .systemFont(ofSize: 18, weight: .semibold)
        button.alignment = .center
        button.contentTintColor = theme.text
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 1
        button.layer?.setAppearanceBorder(theme.sep)
        button.layer?.setAppearanceBackground(theme.cardAlt)
        button.layer?.masksToBounds = true
        button.setButtonType(.momentaryChange)
        button.toolTip = "设置开始说话快捷键"
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 134).isActive = true
        button.heightAnchor.constraint(equalToConstant: 38).isActive = true
        return button
    }

    private func makeHotkeyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let currentShortcut = RecordingHotkeyShortcut.current
        if case .custom(let custom) = currentShortcut {
            addHotkeyMenuItem(to: menu,
                              title: custom.displayName,
                              representedObject: "custom-current",
                              symbolName: "keyboard",
                              isSelected: true)
            menu.addItem(.separator())
        }

        for modifier in [
            RecordingHotkeyModifier.option,
            .command,
            .control,
            .shift,
            .fn,
            .rightCommand,
            .rightOption,
            .rightControl,
        ] {
            let isSelected: Bool
            if case .modifier(let selectedModifier) = currentShortcut {
                isSelected = selectedModifier == modifier
            } else {
                isSelected = false
            }
            addHotkeyMenuItem(to: menu,
                              title: modifier.menuTitle,
                              representedObject: modifier.rawValue,
                              symbolName: modifier.symbolName,
                              isSelected: isSelected)
        }

        menu.addItem(.separator())
        addHotkeyMenuItem(to: menu,
                          title: "自定义快捷键…",
                          representedObject: "custom",
                          symbolName: "keyboard.badge.ellipsis",
                          isSelected: false)

        return menu
    }

    @discardableResult
    private func addHotkeyMenuItem(to menu: NSMenu,
                                   title: String,
                                   representedObject: String,
                                   symbolName: String,
                                   isSelected: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(hotkeyMenuItemSelected(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.image = hotkeyMenuImage(symbolName: symbolName)
        item.state = isSelected ? .on : .off
        menu.addItem(item)
        return item
    }

    private func hotkeyMenuImage(symbolName: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        let image = base.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) ?? base
        image.isTemplate = true
        return image
    }

    @objc private func showHotkeyMenu(_ sender: NSButton) {
        let menu = makeHotkeyMenu()
        let selectedItem = menu.items.first { $0.state == .on }
        menu.popUp(positioning: selectedItem, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
    }

    @objc private func hotkeyMenuItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        if raw == "custom" {
            presentCustomHotkeyPanel()
            invalidate(.home)
            return
        }
        if raw == "custom-current" {
            return
        }
        guard let modifier = RecordingHotkeyModifier(rawValue: raw) else { return }
        RecordingHotkeyShortcut.useModifier(modifier)
        NotificationCenter.default.post(name: .voicePolishHotkeyDidChange, object: nil)
        invalidate(.home)
    }

    private func presentCustomHotkeyPanel() {
        let recorder = HotkeyRecorderView(frame: NSRect(x: 0, y: 0, width: 360, height: 118))
        if case .custom(let custom) = RecordingHotkeyShortcut.current {
            recorder.setShortcut(custom)
        }

        let alert = NSAlert()
        alert.messageText = "自定义快捷键"
        alert.informativeText = "点击输入框，然后按下你想用于开始说话的快捷键。"
        alert.accessoryView = recorder
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "恢复默认")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            guard let shortcut = recorder.shortcut else {
                showHotkeyAlert("还没有录入快捷键", detail: "请点击输入框，然后按下一个组合键。")
                return
            }
            if let warning = shortcut.conflictWarning, !confirmRiskyHotkey(warning) {
                return
            }
            RecordingHotkeyShortcut.useCustom(shortcut)
            NotificationCenter.default.post(name: .voicePolishHotkeyDidChange, object: nil)
            invalidate(.home)
        case .alertSecondButtonReturn:
            RecordingHotkeyShortcut.useModifier(.option)
            NotificationCenter.default.post(name: .voicePolishHotkeyDidChange, object: nil)
            invalidate(.home)
        default:
            break
        }
    }

    private func confirmRiskyHotkey(_ warning: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "这个快捷键可能会冲突"
        alert.informativeText = warning
        alert.addButton(withTitle: "仍然保存")
        alert.addButton(withTitle: "重新设置")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showHotkeyAlert(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func makeStatsGrid(_ items: [(String, Int, String)]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 10
        for item in items {
            row.addArrangedSubview(makeStatCard(label: item.0, value: item.1, sub: item.2))
        }
        return row
    }

    private func makeStatCard(label labelText: String, value: Int, sub subText: String) -> NSView {
        let card = makeCard()

        let eyebrow = label(labelText, size: 11, weight: .medium, color: theme.text3)
        let big = label(formatNumber(value), size: 30, weight: .bold, color: theme.text)
        big.font = monoFont(size: 30, weight: .bold)
        big.maximumNumberOfLines = 1          // 数字绝不换行（窄窗口下宁可整体缩小，不断成两行）
        big.lineBreakMode = .byClipping
        let unit = label("字", size: 13, weight: .regular, color: theme.text3)
        let sub = label(subText, size: 11, weight: .regular, color: theme.text3)

        let valueRow = NSStackView()
        valueRow.orientation = .horizontal
        valueRow.alignment = .lastBaseline
        valueRow.spacing = 3
        valueRow.addArrangedSubview(big)
        valueRow.addArrangedSubview(unit)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        stack.addArrangedSubview(eyebrow)
        stack.addArrangedSubview(valueRow)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(6, after: eyebrow)
        stack.setCustomSpacing(4, after: valueRow)

        mount(stack, in: card)
        return card
    }

    // MARK: - 激活 / 升级卡片

    private var upgradeSheet: NSWindow?

    /// 侧边栏底部额度升级卡片（仅未激活时显示，激活后消失）。
    /// 标题 + 今日额度进度条 + 说明 + 墨黑升级按钮；点击任意处弹出激活窗。
    private func makeSidebarUpgradeButton() -> NSView? {
        // 填了自己识别 Key 的人：不管服务器有没有给他起试用，他走的是直连，显示自带 Key 卡
        if CloudASRTranscriber().isConfigured() && TrialManager.shared.isTrialAvailable {
            return makeSidebarUpgradeButtonBYOK()
        }
        if TrialManager.shared.isInTrial && !TrialManager.shared.isTotalExhausted {
            return makeSidebarUpgradeButtonTrial()
        } else if TrialManager.shared.trialExpired || TrialManager.shared.isTotalExhausted {
            return makeSidebarUpgradeButtonExpired()
        } else if TrialManager.shared.isTrialAvailable {
            return makeSidebarUpgradeButtonBYOK()
        }
        return nil   // 自己编译的开源版没有托管服务，不推会员
    }

    /// 侧边栏卡片——会员续费提醒：一次性年卡/赠送的会员 14 天内到期时出现；自动续费的到期前不打扰，
    /// 真到期（续费失败）才出现。整卡点击 → 定价页。
    private func makeSidebarMemberRenewalCard() -> NSView? {
        let license = LicenseManager.shared
        guard license.isMember, TrialManager.shared.isTrialAvailable else { return nil }
        // 填了自己的 Key 且没选「优先走会员」的人（创世用户默认如此），会员到不到期都不影响使用，不催
        if CloudASRTranscriber().isConfigured() && !HostedRoute.memberFirst { return nil }
        let expired = license.isMemberExpired()
        let daysLeft = license.memberDaysLeft() ?? 0
        guard expired || (!license.memberAutoRenew && daysLeft <= 14) else { return nil }

        let card = makeUpgradeCard()
        let title = label(expired ? "会员已到期" : "会员还剩 \(daysLeft) 天", size: 13.5, weight: .semibold, color: theme.text)
        let sub = label(expired ? "续费后继续免配置使用；也可以在「模型」填入自己的 Key，永久免费。"
                                : "有效期至 \(license.memberExpiresDay ?? "—")。到期后可续费，或在「模型」填入自己的 Key。",
                        size: 11.5, weight: .regular, color: theme.text2)
        sub.maximumNumberOfLines = 0
        let btn = makeSolidButton(title: "续费 →")

        let stack = makeUpgradeStack(card: card)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(8, after: title)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(12, after: sub)
        stack.addArrangedSubview(btn)
        NSLayoutConstraint.activate([
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            btn.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        finishUpgradeCard(card: card, stack: stack)
        return card
    }

    /// 侧边栏卡片——试用中状态。
    private func makeSidebarUpgradeButtonTrial() -> NSView {
        // 对用户只讲一个数：7 天总额。用服务器记的 totalUsed，
        // 而非 InputStats 的本地输入统计——后者含非试用使用，会显示超额。
        let used = TrialManager.shared.totalUsed
        let trialLimit = TrialManager.shared.displayTotalLimit
        let ratio = max(min(CGFloat(used) / CGFloat(trialLimit), 1), 0.001)
        let limitStr = TrialManager.formatChars(trialLimit)

        // 注意：这里不要向服务器刷新试用状态——本函数在每次 rebuildSidebar 时都会跑，
        // 而 rebuildSidebar 会被多种通知触发；刷新统一放在 App 激活时（appDidBecomeActive）做一次。

        let card = makeUpgradeCard()

        // 标题行：「免费试用中」（左）+ 「剩 N 天」（右）
        let titleLbl = label("免费试用中", size: 13.5, weight: .semibold, color: theme.text)
        let daysLbl = label("剩 \(TrialManager.shared.daysLeft) 天", size: 12, weight: .semibold, color: theme.text2)
        daysLbl.setContentHuggingPriority(.required, for: .horizontal)
        let titleSpacer = NSView()
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
        titleRow.addArrangedSubview(titleLbl)
        titleRow.addArrangedSubview(titleSpacer)
        titleRow.addArrangedSubview(daysLbl)

        // 数字行：已用 3,200 / 10,000 字
        let (numRow, track) = makeProgressNumRow(usedStr: TrialManager.formatChars(used), limitStr: limitStr, ratio: ratio)

        // 说明
        let sub = label("7 天共 \(limitStr) 字，用完或到期后可开通会员，或填自己的 Key 永久免费。",
                        size: 11.5, weight: .regular, color: theme.text2)
        sub.maximumNumberOfLines = 0

        // Ghost 按钮（白底 + 边框 + 深色文字）
        let btn = makeGhostButton(title: "查看方案 →")

        let stack = makeUpgradeStack(card: card)
        stack.addArrangedSubview(titleRow)
        stack.setCustomSpacing(9, after: titleRow)
        stack.addArrangedSubview(numRow)
        stack.setCustomSpacing(7, after: numRow)
        stack.addArrangedSubview(track)
        stack.setCustomSpacing(11, after: track)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(12, after: sub)
        stack.addArrangedSubview(btn)
        NSLayoutConstraint.activate([
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            numRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            track.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            btn.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        finishUpgradeCard(card: card, stack: stack)
        return card
    }

    /// 侧边栏卡片——试用已结束状态。
    private func makeSidebarUpgradeButtonExpired() -> NSView {
        let card = makeUpgradeCard()

        // 额度先用完（还没满 7 天）和到期是两回事，分开说，免得用户以为「怎么没到 7 天就结束了」
        let quotaUsedUp = TrialManager.shared.isTotalExhausted && !TrialManager.shared.trialExpired
        let title = label(quotaUsedUp ? "免费试用额度已用完" : "免费试用已结束",
                          size: 13.5, weight: .semibold, color: theme.text)

        let lead = quotaUsedUp ? "7 天共 \(TrialManager.formatChars(TrialManager.shared.displayTotalLimit)) 字已用完。" : ""
        let sub = label(lead + "开通会员直接用；或在「模型」填入自己的 Key，永久免费。",
                        size: 11.5, weight: .regular, color: theme.text2)
        sub.maximumNumberOfLines = 0

        // 墨黑按钮 → 定价页（整张卡点击同去）：两条路都在那里
        let btn = makeSolidButton(title: "查看方案 →")

        let stack = makeUpgradeStack(card: card)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(8, after: title)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(12, after: sub)
        stack.addArrangedSubview(btn)
        NSLayoutConstraint.activate([
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            btn.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        finishUpgradeCard(card: card, stack: stack)
        return card
    }

    /// 侧边栏卡片——自带 Key 状态。2026-09-14 起不再限每周字数，只留一个温和的会员入口；
    /// 已激活后整张卡不显示。
    private func makeSidebarUpgradeButtonBYOK() -> NSView {
        let card = makeUpgradeCard()

        let title = label("自带 Key · 永久免费", size: 13.5, weight: .semibold, color: theme.text)

        let sub = label("不限字数、不限时间。不想折腾 Key？开通会员，装好就能用。",
                        size: 11.5, weight: .regular, color: theme.text2)
        sub.maximumNumberOfLines = 0

        let btn = makeGhostButton(title: "了解会员 →")

        let stack = makeUpgradeStack(card: card)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(8, after: title)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(12, after: sub)
        stack.addArrangedSubview(btn)
        NSLayoutConstraint.activate([
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            btn.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        finishUpgradeCard(card: card, stack: stack)
        return card
    }

    // MARK: Upgrade card helpers

    /// 创建卡片容器（圆角、边框、背景）。
    private func makeUpgradeCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.setAppearanceBackground(theme.cardAlt)
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.setAppearanceBorder(theme.sep)
        return card
    }

    /// 创建卡片内的垂直 stack（14pt insets）。
    private func makeUpgradeStack(card: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        return stack
    }

    /// 将 stack 嵌入 card 并绑定四边，同时挂上点击手势。
    private func finishUpgradeCard(card: NSView, stack: NSStackView, action: Selector = #selector(upgradeSidebarTapped)) {
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: action)
        card.addGestureRecognizer(click)
    }


    /// 进度数字行（已用 N / Limit 字 ⓘ）+ 进度条，返回两个视图。
    private func makeProgressNumRow(usedStr: String, limitStr: String, ratio: CGFloat)
        -> (numRow: NSStackView, track: NSView) {
        let prefix = label("已用", size: 11.5, weight: .regular, color: theme.text3)
        prefix.setContentHuggingPriority(.required, for: .horizontal)
        let num = label("\(usedStr) / \(limitStr)", size: 13, weight: .semibold, color: theme.text)
        num.setContentHuggingPriority(.required, for: .horizontal)
        let unit = label("字", size: 11.5, weight: .regular, color: theme.text3)
        unit.setContentHuggingPriority(.required, for: .horizontal)
        let info = NSImageView()
        info.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "额度说明")
        info.contentTintColor = theme.text3
        info.toolTip = "试用 7 天内共 \(limitStr) 字，不按天重置；用完或满 7 天试用结束"
        info.translatesAutoresizingMaskIntoConstraints = false
        info.widthAnchor.constraint(equalToConstant: 13).isActive = true
        info.heightAnchor.constraint(equalToConstant: 13).isActive = true
        let numSpacer = NSView()
        let numRow = NSStackView()
        numRow.orientation = .horizontal
        numRow.alignment = .centerY
        numRow.spacing = 4
        numRow.addArrangedSubview(prefix)
        numRow.addArrangedSubview(num)
        numRow.addArrangedSubview(unit)
        numRow.addArrangedSubview(numSpacer)
        numRow.addArrangedSubview(info)

        let track = NSView()
        track.translatesAutoresizingMaskIntoConstraints = false
        track.wantsLayer = true
        track.layer?.setAppearanceBackground(Self.meterTrack)
        track.layer?.cornerRadius = 3
        let fill = NSView()
        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.wantsLayer = true
        fill.layer?.setAppearanceBackground(theme.accent)
        fill.layer?.cornerRadius = 3
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 6),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: ratio),
        ])
        return (numRow, track)
    }

    /// 墨黑实心按钮。
    private func makeSolidButton(title: String) -> NSView {
        let btn = NSView()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.wantsLayer = true
        btn.layer?.setAppearanceBackground(theme.accent)
        btn.layer?.cornerRadius = 9
        let lbl = label(title, size: 13, weight: .semibold, color: theme.onAccent)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        btn.addSubview(lbl)
        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: 34),
            lbl.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
        ])
        return btn
    }

    /// Ghost 按钮（白底 + sep 边框 + 深色文字）。
    private func makeGhostButton(title: String) -> NSView {
        let btn = NSView()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.wantsLayer = true
        btn.layer?.setAppearanceBackground(theme.card)
        btn.layer?.cornerRadius = 9
        btn.layer?.borderWidth = 1
        btn.layer?.setAppearanceBorder(theme.sep)
        let lbl = label(title, size: 13, weight: .semibold, color: theme.text)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        btn.addSubview(lbl)
        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: 34),
            lbl.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
        ])
        return btn
    }

    @objc private func upgradeSidebarTapped() {
        showUpgradeSheet()
    }

    /// 弹出完整定价页（三种用法卡片 + FAQ + 保留授权码激活）。激活成功后窗口关闭、侧边栏按钮消失。
    private func showUpgradeSheet() {
        guard let host = window, upgradeSheet == nil else { return }

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sheet.title = "Typefree"
        sheet.titlebarAppearsTransparent = true
        sheet.isReleasedWhenClosed = false
        upgradeSheet = sheet

        let cv = AppearanceObservingView()
        cv.wantsLayer = true
        cv.layer?.setAppearanceBackground(theme.bg)
        sheet.contentView = cv

        // 内容较高，整页放进可滚动容器，窗口再矮也能看全 FAQ。
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        cv.addSubview(scroll)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        // Header（居中标题 + 副标题）
        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .centerX
        headerStack.spacing = 8
        let title = label("Typefree · 自然说话，清楚输入", size: 21, weight: .bold, color: theme.text)
        title.alignment = .center
        // 开源（Ray 2026-09-14：付费页要凸显开源）：软件本身开源免费，会员买的是免配置的服务
        let ossRow = NSStackView()
        ossRow.orientation = .horizontal
        ossRow.alignment = .centerY
        ossRow.spacing = 8
        ossRow.addArrangedSubview(makeDarkTag("开源"))
        ossRow.addArrangedSubview(label("软件开源、永久免费；会员买的是免配置的识别和润色服务", size: 13, weight: .regular, color: theme.text2))
        ossRow.addArrangedSubview(makeLinkButton(title: "查看源码 →", urlString: AppLinks.sourceCodeURL))
        headerStack.addArrangedSubview(title)
        headerStack.addArrangedSubview(ossRow)
        stack.addArrangedSubview(headerStack)
        stack.setCustomSpacing(28, after: headerStack)

        // 三张等高卡片
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.alignment = .top
        cards.distribution = .fillEqually
        cards.spacing = 18
        cards.addArrangedSubview(makeTrialPricingCard())
        cards.addArrangedSubview(makeBuyPricingCard())
        cards.addArrangedSubview(makeBYOKPricingCard())
        stack.addArrangedSubview(cards)
        stack.setCustomSpacing(26, after: cards)

        // 激活行（次要：已经购买过 → 粘贴授权码激活）
        let activateBlock = makeActivateBlock()
        stack.addArrangedSubview(activateBlock)
        stack.setCustomSpacing(34, after: activateBlock)

        // FAQ
        let faq = makeFAQBlock()
        stack.addArrangedSubview(faq)

        scroll.documentView = doc

        // 右上角关闭按钮（Esc 同样可关）——sheet 没有系统红绿灯，必须自己给出口
        let closeBtn = NSButton()
        closeBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")
        closeBtn.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        closeBtn.isBordered = false
        closeBtn.contentTintColor = theme.text3
        closeBtn.target = self
        closeBtn.action = #selector(upgradeSheetCloseTapped)
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: cv.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            // 内容整体居中，最宽 1000，左右各留 30 边距
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 44),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -44),
            stack.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: doc.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -30),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 1000),
            headerStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cards.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activateBlock.widthAnchor.constraint(equalTo: stack.widthAnchor),
            faq.widthAnchor.constraint(equalTo: stack.widthAnchor),   // FAQ 用满三卡总宽，两列铺开
            closeBtn.topAnchor.constraint(equalTo: cv.topAnchor, constant: 14),
            closeBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
        ])

        host.beginSheet(sheet, completionHandler: nil)
    }

    // MARK: Pricing page pieces

    /// 软标签（浅灰底 + text2 文字），如「新用户」「自带 Key」「永久免费」。
    private func makeSoftTag(_ text: String) -> NSView { makeTag(text, bg: Self.softFill, fg: theme.text3) }

    /// 深标签（强调色底 + onAccent 文字），如「推荐」。
    private func makeDarkTag(_ text: String) -> NSView { makeTag(text, bg: theme.accent, fg: theme.onAccent) }

    private func makeTag(_ text: String, bg: NSColor, fg: NSColor, size: CGFloat = 11) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.setAppearanceBackground(bg)
        let l = label(text, size: size, weight: .semibold, color: fg)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.maximumNumberOfLines = 1
        l.setContentCompressionResistancePriority(.required, for: .horizontal)   // 宁可溢出也不折行：折行会把胶囊撑高、压到上一行
        v.addSubview(l)
        let hPad: CGFloat = size < 11 ? 7 : 8
        let vPad: CGFloat = size < 11 ? 2.5 : 2
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: hPad),
            l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -hPad),
            l.topAnchor.constraint(equalTo: v.topAnchor, constant: vPad),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -vPad),
        ])
        return v
    }

    /// 卡片里的一条 ✓ 功能行；strongPrefix 加粗、muted 用浅色。
    private func makeFeatureRow(_ text: String, strongPrefix: String? = nil, muted: String? = nil) -> NSView {
        let check = label("✓", size: 13, weight: .semibold, color: theme.text)
        check.setContentHuggingPriority(.required, for: .horizontal)

        let body = NSTextField(labelWithString: "")
        body.translatesAutoresizingMaskIntoConstraints = false
        body.isSelectable = false
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 0
        let attr = NSMutableAttributedString()
        if let sp = strongPrefix {
            attr.append(NSAttributedString(string: sp, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: theme.text]))
        }
        attr.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: theme.text]))
        if let m = muted {
            attr.append(NSAttributedString(string: m, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: theme.text2]))
        }
        body.attributedStringValue = attr

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 9
        row.addArrangedSubview(check)
        row.addArrangedSubview(body)
        return row
    }

    /// 灰色「当前/禁用」按钮（浅灰底 + text3 文字，不可点击），对应设计稿 .btn.cur。
    private func makeCurrentButton(title: String) -> NSView {
        let btn = NSView()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.wantsLayer = true
        btn.layer?.setAppearanceBackground(Self.softFill)
        btn.layer?.cornerRadius = 9
        let lbl = label(title, size: 13, weight: .semibold, color: theme.text3)
        lbl.alignment = .center
        lbl.translatesAutoresizingMaskIntoConstraints = false
        btn.addSubview(lbl)
        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: 40),
            lbl.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
        ])
        return btn
    }

    /// 卡片外壳：圆角白卡，highlighted 时描 2px 近黑边。内部把传入的子视图竖排。
    private func makePricingCard(highlighted: Bool, content: (NSStackView) -> Void) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.setAppearanceBackground(theme.card)
        card.layer?.cornerRadius = 18
        card.layer?.borderWidth = highlighted ? 2 : 1
        card.layer?.setAppearanceBorder((highlighted ? theme.accent : theme.sep))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 22, bottom: 24, right: 22)
        content(stack)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }
        return card
    }

    /// 卡片名称行：名字 + 若干标签。
    private func makeCardNameRow(_ name: String, tags: [NSView]) -> NSView {
        let nameLbl = label(name, size: 17, weight: .semibold, color: theme.text)
        nameLbl.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(nameLbl)
        tags.forEach { row.addArrangedSubview($0) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }

    /// 卡①：免费试用（状态自适应按钮）。
    private func makeTrialPricingCard() -> NSView {
        makePricingCard(highlighted: false) { stack in
            let nameRow = makeCardNameRow("免费试用", tags: [makeSoftTag("新用户")])
            let price = makePriceRow(main: "免费", per: "· 7 天")
            let desc = label("下载即用，零配置", size: 13, weight: .regular, color: theme.text2)

            let btn: NSView
            if LicenseManager.shared.isActivated {
                btn = makeCurrentButton(title: "已激活 · 无需试用")
            } else if CloudASRTranscriber().isConfigured() && TrialManager.shared.isTrialAvailable {
                btn = makeCurrentButton(title: "已填自己的 Key · 无需试用")
            } else if TrialManager.shared.isTotalExhausted {
                btn = makeCurrentButton(title: "试用额度已用完")
            } else if TrialManager.shared.isInTrial {
                btn = makeCurrentButton(title: "试用中 · 剩 \(TrialManager.shared.daysLeft) 天")
            } else if TrialManager.shared.trialExpired {
                btn = makeCurrentButton(title: "试用已结束")
            } else if !TrialManager.shared.isTrialAvailable {
                btn = makeCurrentButton(title: "此版本不含试用")
            } else {
                btn = makeCurrentButton(title: "未开始")
            }

            stack.addArrangedSubview(nameRow)
            stack.setCustomSpacing(14, after: nameRow)
            stack.addArrangedSubview(price)
            stack.setCustomSpacing(6, after: price)
            stack.addArrangedSubview(desc)
            stack.setCustomSpacing(18, after: desc)
            stack.addArrangedSubview(btn)
            stack.setCustomSpacing(20, after: btn)
            for f in [
                makeFeatureRow("7 天共 \(TrialManager.formatChars(TrialManager.shared.displayTotalLimit)) 字"),
                makeFeatureRow("识别 + AI 润色，", muted: "费用我们承担"),
                makeFeatureRow("不用填 Key，按一下就出字"),
                makeFeatureRow("到期后可转下面两种"),
            ] {
                stack.addArrangedSubview(f)
                stack.setCustomSpacing(11, after: f)
            }
        }
    }

    /// 卡②：年付会员（高亮，墨黑实心按钮 → 官网付款页）。免配置：识别 / 润色 / 问 AI 走我们的托管服务。
    /// （2026-09-14 去掉赞助版：Paddle 禁止销售捐款/赞助类商品）
    private func makeBuyPricingCard() -> NSView {
        makePricingCard(highlighted: true) { stack in
            let nameRow = makeCardNameRow("会员", tags: [makeDarkTag("推荐"), makeSoftTag("免配置")])
            let price = makePriceRow(main: "¥188", per: "· 一年")
            let desc = label("不用申请任何 Key，装好就能用", size: 13, weight: .regular, color: theme.text2)
            desc.maximumNumberOfLines = 0

            let license = LicenseManager.shared
            let btn: NSView
            if !TrialManager.shared.isTrialAvailable {
                // 自己编译的开源版没有托管服务器地址，会员通道用不了（试用同理）
                btn = makeCurrentButton(title: "此版本不含会员服务")
            } else if license.isMember && !license.isMemberExpired() {
                btn = makeCurrentButton(title: "会员有效 · 至 \(license.memberExpiresDay ?? "—")")
            } else {
                let solid = makeSolidButton(title: license.isMember ? "续费 →" : "开通会员 →")
                let click = NSClickGestureRecognizer(target: self, action: #selector(pricingBuyTapped))
                solid.addGestureRecognizer(click)
                btn = solid
            }

            stack.addArrangedSubview(nameRow)
            stack.setCustomSpacing(14, after: nameRow)
            stack.addArrangedSubview(price)
            stack.setCustomSpacing(6, after: price)
            stack.addArrangedSubview(desc)
            stack.setCustomSpacing(18, after: desc)
            stack.addArrangedSubview(btn)
            stack.setCustomSpacing(20, after: btn)
            for f in [
                makeFeatureRow("识别 + 润色 + 问 AI 全包含"),   // 文字过长会把对勾挤没；「免配置」已在卡片标签里
                makeFeatureRow("银行卡自动续费，", muted: "或微信买一年"),
                makeFeatureRow("随时可取消自动续费"),
                makeFeatureRow("到期后仍可填自己的 Key 免费用"),
            ] {
                stack.addArrangedSubview(f)
                stack.setCustomSpacing(11, after: f)
            }
        }
    }

    /// 卡③：自带 Key·免费（ghost 按钮 → 模型页并关闭本页）。
    private func makeBYOKPricingCard() -> NSView {
        makePricingCard(highlighted: false) { stack in
            let nameRow = makeCardNameRow("自带 Key", tags: [makeSoftTag("永久免费")])
            let price = makePriceRow(main: "免费", per: "· 不限时间")
            let desc = label("填入你自己的 API Key", size: 13, weight: .regular, color: theme.text2)

            let ghost = makeGhostButton(title: "去配置 →")
            ghost.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pricingConfigureTapped)))

            stack.addArrangedSubview(nameRow)
            stack.setCustomSpacing(14, after: nameRow)
            stack.addArrangedSubview(price)
            stack.setCustomSpacing(6, after: price)
            stack.addArrangedSubview(desc)
            stack.setCustomSpacing(18, after: desc)
            stack.addArrangedSubview(ghost)
            stack.setCustomSpacing(20, after: ghost)
            for f in [
                makeFeatureRow("不限字数"),
                makeFeatureRow("永久免费，不限时间"),
                makeFeatureRow("费用走你自己的 Key"),
                makeFeatureRow("火山 / 千问 等主流厂商适配"),
            ] {
                stack.addArrangedSubview(f)
                stack.setCustomSpacing(11, after: f)
            }
        }
    }

    /// 价格行：大号主价 + 可选「· 7 天」后缀 + 可选划线原价。
    private func makePriceRow(main: String, per: String?, old: String? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .lastBaseline
        row.spacing = 8
        let mainLbl = label(main, size: 30, weight: .bold, color: theme.text)
        row.addArrangedSubview(mainLbl)
        if let per = per {
            row.addArrangedSubview(label(per, size: 14, weight: .regular, color: theme.text3))
        }
        if let old = old {
            let oldLbl = NSTextField(labelWithAttributedString: NSAttributedString(string: old, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: theme.text3,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]))
            oldLbl.isSelectable = false
            row.addArrangedSubview(oldLbl)
        }
        return row
    }

    @objc private func pricingBuyTapped() {
        if let url = URL(string: AppLinks.purchaseURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func pricingConfigureTapped() {
        closeUpgradeSheet()
        selectPage(.model)
    }

    /// 激活行：「已经购买过了？」+ 授权码输入框 + 激活按钮 + 错误提示（沿用既有激活逻辑）。
    private func makeActivateBlock() -> NSView {
        let prompt = label("已经购买过了？粘贴授权码激活", size: 13, weight: .regular, color: theme.text2)
        prompt.alignment = .center

        // 授权码输入框：透明 borderless 字段 + 圆角浅灰底容器（同词库/反馈输入框做法），
        // 去掉系统蓝聚焦环；文字左右内缩 12pt，和整页灰/墨黑统一。
        let field = NSTextField()
        field.placeholderString = "粘贴授权码（购买后邮件里的 TF-XXXX-…）"
        field.font = monoFont(size: 12, weight: .regular)
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = theme.text
        field.translatesAutoresizingMaskIntoConstraints = false
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.lineBreakMode = .byTruncatingTail
        }
        licenseKeyField = field

        let fieldWrap = NSView()
        fieldWrap.wantsLayer = true
        fieldWrap.layer?.cornerRadius = 9
        fieldWrap.layer?.borderWidth = 1
        fieldWrap.layer?.setAppearanceBorder(theme.sep)
        fieldWrap.layer?.setAppearanceBackground(theme.cardAlt)
        fieldWrap.translatesAutoresizingMaskIntoConstraints = false
        fieldWrap.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: fieldWrap.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: fieldWrap.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: fieldWrap.centerYAnchor),
        ])

        // 激活按钮：墨黑自绘（onAccent 白字），仍是 NSButton 子类——
        // activateLicenseTapped 依赖 sender(NSButton) 改 isEnabled/title，激活逻辑保持不变。
        let activateBtn = SolidLabelButton(title: "激活", color: theme.onAccent,
                                           target: self, action: #selector(activateLicenseTapped(_:)))
        activateBtn.layer?.setAppearanceBackground(theme.accent)
        activateBtn.keyEquivalent = "\r"

        let status = label("", size: 12, weight: .regular, color: theme.danger)
        status.alignment = .center
        status.isHidden = true
        licenseStatusLabel = status

        fieldWrap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        activateBtn.setContentHuggingPriority(.required, for: .horizontal)
        activateBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
        let inputRow = NSStackView()
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 10
        inputRow.distribution = .fill
        inputRow.addArrangedSubview(fieldWrap)
        inputRow.addArrangedSubview(activateBtn)

        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .centerX
        block.spacing = 12
        block.translatesAutoresizingMaskIntoConstraints = false
        block.addArrangedSubview(prompt)
        block.addArrangedSubview(inputRow)
        block.addArrangedSubview(status)

        // 输入框 + 按钮一行，整行约 500 居中；输入框撑开，按钮固定宽，两者等高 40。
        NSLayoutConstraint.activate([
            inputRow.widthAnchor.constraint(equalToConstant: 500),
            fieldWrap.heightAnchor.constraint(equalToConstant: 40),
            activateBtn.heightAnchor.constraint(equalToConstant: 40),
            activateBtn.widthAnchor.constraint(equalToConstant: 84),
            status.widthAnchor.constraint(equalToConstant: 500),
        ])
        return block
    }

    /// FAQ 区块：标题 + 4 条问答，排成 2 行 × 2 列，整块用满上方三张卡的总宽。
    private func makeFAQBlock() -> NSView {
        let items: [(String, String)] = [
            ("可以一直免费用吗？",
             "可以。前 7 天我们请你免费体验（零配置）；到期后填入你自己的 API Key，永久免费，不限字数。"),
            ("会员和免费有什么区别？",
             "功能一样。免费需要你自己去厂商申请 API Key，费用走你自己的账户；会员不用配置，识别和润色走我们的服务。"),
            ("会员会自动扣费吗？",
             "用银行卡开通的每年自动续费，想停直接回复购买邮件即可取消；用微信买的是一次性一年，不会自动扣费。"),
            ("我的 API Key 安全吗？",
             "你的 Key 只保存在本机，绝不上传我们的服务器。"),
        ]

        // 单条问答：顶边分隔线 + 问题 + 自动换行的答案。
        func makeQA(_ q: String, _ a: String) -> NSView {
            let cell = NSStackView()
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 0
            let line = NSView()
            line.wantsLayer = true
            line.layer?.setAppearanceBackground(theme.sep)
            line.translatesAutoresizingMaskIntoConstraints = false
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            let qLbl = label(q, size: 14, weight: .semibold, color: theme.text)
            qLbl.maximumNumberOfLines = 0
            let aLbl = label(a, size: 13, weight: .regular, color: theme.text2)
            aLbl.maximumNumberOfLines = 0
            cell.addArrangedSubview(line)
            cell.setCustomSpacing(14, after: line)
            cell.addArrangedSubview(qLbl)
            cell.setCustomSpacing(8, after: qLbl)
            cell.addArrangedSubview(aLbl)
            line.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            qLbl.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            aLbl.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            return cell
        }

        // 两两一行；列间 36 间距，列等宽（fillEqually）。
        func makeFAQRow(_ left: NSView, _ right: NSView) -> NSStackView {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 36
            row.addArrangedSubview(left)
            row.addArrangedSubview(right)
            return row
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = label("常见问题", size: 16, weight: .semibold, color: theme.text)
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(10, after: heading)

        let row1 = makeFAQRow(makeQA(items[0].0, items[0].1), makeQA(items[1].0, items[1].1))
        let row2 = makeFAQRow(makeQA(items[2].0, items[2].1), makeQA(items[3].0, items[3].1))
        stack.addArrangedSubview(row1)
        stack.setCustomSpacing(4, after: row1)
        stack.addArrangedSubview(row2)
        row1.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        row2.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    @objc private func upgradeSheetCloseTapped() {
        closeUpgradeSheet()
    }

    private func closeUpgradeSheet() {
        if let sheet = upgradeSheet {
            window?.endSheet(sheet)
            upgradeSheet = nil
        }
    }

    @objc private func activateLicenseTapped(_ sender: NSButton) {
        let key = licenseKeyField?.stringValue ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showLicenseStatus("请先粘贴授权码", isError: true)
            return
        }
        sender.isEnabled = false
        sender.title = "激活中…"
        showLicenseStatus("正在激活…", isError: false)

        let deviceName = Host.current().localizedName ?? "Mac"
        LicenseManager.shared.activate(key: key, instanceName: deviceName) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.closeUpgradeSheet()
                self.rebuildSidebar()                // 升级按钮消失
                self.invalidate(self.selectedPage)   // 刷新当前页（关于页会显示「已激活」小字）
            case .failure(let err):
                sender.isEnabled = true
                sender.title = "激活"
                self.showLicenseStatus(Self.licenseErrorText(err), isError: true)
            }
        }
    }

    private func showLicenseStatus(_ text: String, isError: Bool) {
        guard let label = licenseStatusLabel else { return }
        label.stringValue = text
        label.textColor = isError ? theme.danger : theme.text3
        label.isHidden = false
    }

    private static func licenseErrorText(_ err: LicenseManager.ActivationError) -> String {
        switch err {
        case .emptyKey:      return "请先粘贴授权码"
        case .invalidKey:    return "授权码无效，请检查是否复制完整"
        case .limitReached:  return "这个授权码已在另一台 Mac 上激活。换新机请到 typefree.app/recover 重置后再试。"
        case .network(let m): return "激活失败：\(m)"
        }
    }

    private func makeHealthCard() -> NSView {
        let card = makeCard()
        let micStatus = micStatusInfo()
        let accessOK = AXIsProcessTrusted()
        let asrOK = CloudASRTranscriber().isConfigured()
        let polishOK = isPolishConfigured()
        let polishOff = (config.string(forKey: "polish_provider") ?? "qwen") == "none"
        // 按真实走的通道显示：会员优先时填了 Key 也显示「会员」；没填 Key 时会员 / 试用都算「可用」
        func hostedRow(ownKey: Bool) -> (sub: String, tail: String)? {
            switch HostedRoute.current(ownKeyConfigured: ownKey) {
            case .member: return ("会员 · 免配置，用我们提供的", "会员")
            case .trial: return ("试用中 · 用我们提供的", "试用中")
            case .none: return nil
            }
        }
        let asrHosted = hostedRow(ownKey: asrOK)
        let polishHosted = hostedRow(ownKey: polishOK)

        var rows: [(String, String, Bool, String, Selector?)] = [
            ("麦克风", micStatus.sub, micStatus.ok, micStatus.tail,
             micStatus.ok ? nil : #selector(healthMicRowTapped)),
            ("辅助功能", accessOK ? "可自动粘贴" : "未开启只能复制到剪贴板，点击去系统设置开启",
             accessOK, accessOK ? "已允许" : "未允许",
             accessOK ? nil : #selector(healthAccessibilityRowTapped)),
            asrHosted != nil
                ? ("语音识别", asrHosted!.sub, true, asrHosted!.tail, nil)
                : asrOK
                    ? ("语音识别", "BigASR 可用", true, "已配置", nil)
                    : ("语音识别", "请填写 ASR Key", false, "未配置", nil),
            polishOff
                ? ("AI 润色", "已选「不优化」，直接输出识别原文", true, "已关闭", nil)
                : polishHosted != nil
                    ? ("AI 润色", polishHosted!.sub, true, polishHosted!.tail, nil)
                    : polishOK
                        ? ("AI 润色", "可整理文本", true, "已配置", nil)
                        : ("AI 润色", "请填写润色 Key", false, "未配置", nil),
        ]
        // 设置写不进磁盘时明确亮出来（工单 #9：以前只记日志，用户只看到「每次打开都像第一次」）。
        // 已自动退到备用位置且写得进去的，不算问题，不显示。
        if let failure = VoicePolishConfig.shared.lastWriteFailure {
            rows.append(("设置存储", "写不进磁盘，改动不会保存：\(failure)", false, "无法保存", nil))
        }

        let allOK = rows.allSatisfy { $0.2 }
        let failCount = rows.filter { !$0.2 }.count
        // 全绿默认折叠（这块没信息量），有问题默认展开；用户可手动点开/收起。
        let expanded = healthExpandedOverride ?? !allOK

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0

        stack.addArrangedSubview(makeHealthSummaryRow(allOK: allOK, failCount: failCount, expanded: expanded))
        if expanded {
            stack.addArrangedSubview(makeHairline(insetH: 18))
            for (i, r) in rows.enumerated() {
                stack.addArrangedSubview(makeHealthRow(label: r.0, sub: r.1, ok: r.2, tail: r.3, action: r.4))
                if i < rows.count - 1 {
                    stack.addArrangedSubview(makeHairline(insetH: 18))
                }
            }
        }
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        mount(stack, in: card)
        return card
    }

    /// 摘要行：全绿时绿点「配置就绪 · 一切正常」，有问题时红字「N 项需要处理」；点击切换展开。
    private func makeHealthSummaryRow(allOK: Bool, failCount: Int, expanded: Bool) -> NSView {
        let dot = circle(color: allOK ? theme.ok : theme.danger, size: 8)
        let l = label(allOK ? "配置就绪 · 一切正常" : "\(failCount) 项需要处理",
                      size: 13, weight: .medium, color: allOK ? theme.text : theme.danger)
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down",
                                accessibilityDescription: expanded ? "收起" : "展开")
        chevron.contentTintColor = theme.text3
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let h = NSStackView()
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 12
        h.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        h.addArrangedSubview(dot)
        h.addArrangedSubview(l)
        h.addArrangedSubview(spacer)
        h.addArrangedSubview(chevron)
        h.setCustomSpacing(12, after: dot)
        h.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleHealthExpanded)))
        return h
    }

    private func healthAllOK() -> Bool {
        let hosted = HostedRoute.current(ownKeyConfigured: false) != .none   // 会员/试用走托管通道，不算缺 Key
        return micStatusInfo().ok && AXIsProcessTrusted()
            && (CloudASRTranscriber().isConfigured() || hosted) && (isPolishConfigured() || hosted)
    }

    @objc private func toggleHealthExpanded() {
        let current = healthExpandedOverride ?? !healthAllOK()
        healthExpandedOverride = !current
        invalidate(.home)
    }

    /// 麦克风：没问过 → 直接唤起系统授权弹窗；被拒过 → 系统不允许再弹，只能带用户去系统设置开。
    @objc private func healthMicRowTapped() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.invalidate(.home, .settings) }
            }
        case .denied, .restricted:
            settingsDelegate?.openMicrophoneSettings()
        default:
            break
        }
    }

    @objc private func healthAccessibilityRowTapped() {
        guard !AXIsProcessTrusted() else { return }
        settingsDelegate?.openAccessibilitySettings()
    }

    private func makeHealthRow(label labelText: String, sub: String, ok: Bool, tail: String,
                               action: Selector? = nil) -> NSView {
        let dot = circle(color: ok ? theme.ok : theme.danger, size: 8)
        let l = label(labelText, size: 13, weight: .medium, color: theme.text)
        let s = label(sub, size: 12, weight: .regular, color: theme.text2)
        let t = label(tail, size: 12, weight: .medium, color: ok ? theme.ok : theme.danger)

        l.setContentHuggingPriority(.required, for: .horizontal)
        s.setContentHuggingPriority(.defaultLow, for: .horizontal)
        s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        t.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let h = NSStackView()
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 12
        h.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        h.addArrangedSubview(dot)
        h.addArrangedSubview(l)
        h.addArrangedSubview(s)
        h.addArrangedSubview(spacer)
        h.addArrangedSubview(t)
        h.setCustomSpacing(12, after: dot)
        h.setCustomSpacing(16, after: l)
        h.setCustomSpacing(12, after: s)
        h.setCustomSpacing(0, after: spacer)
        if let action = action {
            h.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: action))
        }
        return h
    }

    private func makeHairline(insetH: CGFloat) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.layer?.setAppearanceBackground(theme.sep)
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: insetH),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -insetH),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            wrap.heightAnchor.constraint(equalToConstant: 1),
        ])
        return wrap
    }

    private func micStatusInfo() -> (ok: Bool, sub: String, tail: String) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return (true, "可录音", "已允许")
        case .denied: return (false, "被拒绝过，点击去系统设置开启", "已拒绝")
        case .restricted: return (false, "受系统限制", "受限")
        case .notDetermined: return (false, "点击申请麦克风权限", "待授权")
        @unknown default: return (false, "未知状态", "未知")
        }
    }

    // MARK: - Page: Explore

    private func buildExplore(into stack: NSStackView) {
        stack.addArrangedSubview(pageHeader(eyebrow: "TYPEFREE / 探索", title: "探索",
                                             sub: "发现新的输入和表达方式，按需开启。"))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makeExploreCard(
            id: "translation", title: "语音翻译", summary: "把说出的话翻译成指定语言，直接输入。",
            rows: [makeDefaultOutputLanguageRow(), makeOutputLanguageCommandRow()],
            demo: .translation,
            detailTitle: "语言与口令设置", details: { self.makeOutputLanguageCommandOptions() }
        ))
        stack.addArrangedSubview(makeMouseHoldToTalkCard())
        stack.addArrangedSubview(makeMouseHoldAskCard())
    }

    private func makeExploreCard(id: String, title: String, summary: String,
                                 control: NSView? = nil, rows: [NSView] = [],
                                 demo: WhatsNewGuide.Feature? = nil,
                                 detailTitle: String = "查看使用方法", details: () -> NSView) -> NSView {
        let card = makeCard()
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        text.addArrangedSubview(label(title, size: 16, weight: .semibold, color: theme.text))
        let desc = label(summary, size: 12.5, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0
        text.addArrangedSubview(desc)
        text.setHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 20
        header.addArrangedSubview(text)
        if let control {
            header.addArrangedSubview(NSView())
            header.addArrangedSubview(control)
        }
        column.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true

        for row in rows {
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
        }

        let expanded = expandedExploreCards.contains(id)
        let disclosure = VPButton(title: expanded ? "收起说明" : detailTitle,
                                  style: .secondary, size: .small, theme: theme,
                                  target: self, action: #selector(exploreCardToggled(_:)))
        disclosure.identifier = NSUserInterfaceItemIdentifier(id)
        disclosure.setAccessibilityExpanded(expanded)
        if let demo {
            // 「看演示」放在「查看使用方法」左边：动画比文字说明更直观，想重看随时点
            let demoButton = VPButton(title: "看演示", style: .secondary, size: .small, theme: theme,
                                      target: self, action: #selector(exploreDemoTapped(_:)))
            demoButton.tag = demo.rawValue
            let buttons = NSStackView(views: [demoButton, disclosure])
            buttons.orientation = .horizontal
            buttons.spacing = 8
            column.addArrangedSubview(buttons)
        } else {
            column.addArrangedSubview(disclosure)
        }
        if expanded {
            let body = details()
            column.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
        }
        mount(column, in: card)
        return card
    }

    private func makeExploreHelp(_ text: String) -> NSView {
        let view = label(text, size: 12.5, weight: .regular, color: theme.text2)
        view.maximumNumberOfLines = 0
        return view
    }

    @objc private func exploreDemoTapped(_ sender: NSButton) {
        guard let feature = WhatsNewGuide.Feature(rawValue: sender.tag) else { return }
        presentGuide(feature: feature, finishTitle: "完成", onlyThisFeature: true)
    }

    @objc private func exploreCardToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if expandedExploreCards.contains(id) {
            expandedExploreCards.remove(id)
        } else {
            expandedExploreCards.insert(id)
        }
        invalidate(.explore)
    }

    // MARK: - Page: Settings

    private func buildSettings(into stack: NSStackView) {
        stack.addArrangedSubview(pageHeader(eyebrow: "TYPEFREE / 设置", title: "设置",
                                             sub: "管理启动、音频、快捷键和权限。"))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        let launchTitle = sectionTitle("启动")
        stack.addArrangedSubview(launchTitle)
        stack.setCustomSpacing(8, after: launchTitle)
        let launchCard = makeLaunchAtLoginCard()
        stack.addArrangedSubview(launchCard)
        stack.setCustomSpacing(24, after: launchCard)

        let appearanceTitle = sectionTitle("外观")
        stack.addArrangedSubview(appearanceTitle)
        stack.setCustomSpacing(8, after: appearanceTitle)
        let appearanceCard = makeAppearanceCard()
        stack.addArrangedSubview(appearanceCard)
        stack.setCustomSpacing(10, after: appearanceCard)
        let dockCard = makeDockIconCard()
        stack.addArrangedSubview(dockCard)
        stack.setCustomSpacing(24, after: dockCard)

        let audioTitle = sectionTitle("音频")
        stack.addArrangedSubview(audioTitle)
        stack.setCustomSpacing(8, after: audioTitle)
        let audioCard = makeAudioCard()
        stack.addArrangedSubview(audioCard)
        stack.setCustomSpacing(10, after: audioCard)
        let cueCard = makeCueSoundCard()
        stack.addArrangedSubview(cueCard)
        stack.setCustomSpacing(24, after: cueCard)

        let hotkeyTitle = sectionTitle("快捷键")
        stack.addArrangedSubview(hotkeyTitle)
        stack.setCustomSpacing(8, after: hotkeyTitle)
        let hotkeyCard = makeHotkeyBehaviorCard()
        stack.addArrangedSubview(hotkeyCard)
        stack.setCustomSpacing(24, after: hotkeyCard)

        let overlayTitle = sectionTitle("录音浮窗")
        stack.addArrangedSubview(overlayTitle)
        stack.setCustomSpacing(8, after: overlayTitle)
        let overlayCard = makeOverlayStyleCard()
        stack.addArrangedSubview(overlayCard)
        stack.setCustomSpacing(24, after: overlayCard)

        // Permissions（个人词库自动学习开关已移至「个人词库」页）
        stack.addArrangedSubview(makePermissionsCard())
    }

    /// 录音浮窗样式选择：两张并排的「静态预览磁贴」，点哪张选哪张（替代原纯文字分段控件）。
    private func makeOverlayStyleCard() -> NSView {
        let card = makeCard()

        let styleLabel = label("颜色样式", size: 12.5, weight: .semibold, color: theme.text2)
        let colorTile = OverlayStyleTile(mono: false, title: "彩色（Siri）", theme: theme)
        let monoTile = OverlayStyleTile(mono: true, title: "墨黑 · 白波", theme: theme)
        let isMono = OverlayStyle.current == .mono
        colorTile.setSelected(!isMono)
        monoTile.setSelected(isMono)
        colorTile.onSelect = { [weak colorTile, weak monoTile] in
            UserDefaults.standard.set(OverlayStyle.colorful.rawValue, forKey: OverlayStyle.userDefaultsKey)
            colorTile?.setSelected(true); monoTile?.setSelected(false)
        }
        monoTile.onSelect = { [weak colorTile, weak monoTile] in
            UserDefaults.standard.set(OverlayStyle.mono.rawValue, forKey: OverlayStyle.userDefaultsKey)
            colorTile?.setSelected(false); monoTile?.setSelected(true)
        }
        for tile in [colorTile, monoTile] {
            tile.widthAnchor.constraint(equalToConstant: 176).isActive = true
        }

        let styleTiles = NSStackView(views: [colorTile, monoTile])
        styleTiles.orientation = .horizontal
        styleTiles.spacing = 12

        let controlsTitle = label("显示取消 / 完成按钮", size: 13, weight: .medium, color: theme.text)
        let controlsDesc = label("开启后，录音浮窗两侧会显示可点击按钮；关闭后恢复旧版完整声波胶囊。切换后下次录音生效。",
                                 size: 12, weight: .regular, color: theme.text3)
        controlsDesc.maximumNumberOfLines = 0
        controlsDesc.lineBreakMode = .byWordWrapping

        let controlsText = NSStackView()
        controlsText.orientation = .vertical
        controlsText.alignment = .leading
        controlsText.spacing = 2
        controlsText.addArrangedSubview(controlsTitle)
        controlsText.addArrangedSubview(controlsDesc)
        controlsText.setHuggingPriority(.defaultLow, for: .horizontal)
        controlsText.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        controlsDesc.widthAnchor.constraint(equalTo: controlsText.widthAnchor).isActive = true

        let controlsToggle = VPToggle(theme: theme, target: self, action: #selector(overlayControlsChanged(_:)))
        controlsToggle.setOn(OverlayControlsMode.current == .buttons, animated: false)
        controlsToggle.setContentHuggingPriority(.required, for: .horizontal)
        controlsToggle.setContentCompressionResistancePriority(.required, for: .horizontal)

        let controlsRow = NSView()
        controlsRow.translatesAutoresizingMaskIntoConstraints = false
        controlsText.translatesAutoresizingMaskIntoConstraints = false
        controlsToggle.translatesAutoresizingMaskIntoConstraints = false
        controlsRow.addSubview(controlsText)
        controlsRow.addSubview(controlsToggle)
        NSLayoutConstraint.activate([
            controlsText.leadingAnchor.constraint(equalTo: controlsRow.leadingAnchor),
            controlsText.topAnchor.constraint(equalTo: controlsRow.topAnchor),
            controlsText.bottomAnchor.constraint(equalTo: controlsRow.bottomAnchor),
            controlsText.trailingAnchor.constraint(equalTo: controlsToggle.leadingAnchor, constant: -16),
            controlsToggle.trailingAnchor.constraint(equalTo: controlsRow.trailingAnchor),
            controlsToggle.centerYAnchor.constraint(equalTo: controlsRow.centerYAnchor)
        ])

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 12
        main.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        main.addArrangedSubview(styleLabel)
        main.addArrangedSubview(styleTiles)
        main.setCustomSpacing(16, after: styleTiles)
        main.addArrangedSubview(controlsRow)
        controlsRow.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -36).isActive = true

        mount(main, in: card)
        return card
    }

    private static let appearanceOptions: [MainWindowAppearance] = [.system, .light, .dark]

    /// 外观：主窗口和问 AI 面板跟随系统 / 浅色 / 深色。录音胶囊等其余窗口仍是浅色。
    private func makeAppearanceCard() -> NSView {
        let card = makeCard()

        let title = label("深色模式", size: 14, weight: .medium, color: theme.text)
        let desc = label("选「跟随系统」时，Mac 切到深色（包括晚上自动切换），主窗口和问 AI 面板也跟着变深。",
                         size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        let seg = VPSegmentedControl(
            labels: ["跟随系统", "浅色", "深色"],
            trackBg: theme.cardAlt,
            trackBorder: theme.sep,
            selBg: theme.segSelBg,
            selBorder: theme.sep,
            selText: theme.text,
            normalText: theme.text2,
            target: self,
            action: #selector(mainWindowAppearanceChanged(_:)))
        seg.selectedSegment = Self.appearanceOptions.firstIndex(of: MainWindowAppearance.current) ?? 0
        seg.widthAnchor.constraint(equalToConstant: 270).isActive = true
        seg.setContentHuggingPriority(.required, for: .horizontal)
        seg.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(seg)

        mount(row, in: card)
        return card
    }

    /// 录音提示音开关（工单 #1003）。布局照抄 Dock 开关卡片。
    private func makeCueSoundCard() -> NSView {
        let card = makeCard()

        let title = label("录音提示音", size: 14, weight: .medium, color: theme.text)
        let desc = label("开始收音和结束录音时各响一声轻音，不用看屏幕也知道录上了。",
                         size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        let toggle = VPToggle(theme: theme, target: self, action: #selector(cueSoundChanged(_:)))
        toggle.setOn(CuePlayer.shared.isEnabled, animated: false)
        toggle.setAccessibilityLabel("录音提示音")

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(toggle)

        mount(row, in: card)
        return card
    }

    @objc private func cueSoundChanged(_ sender: VPToggle) {
        CuePlayer.shared.isEnabled = sender.isOn
        if sender.isOn { CuePlayer.shared.play(.start, force: true) }   // 打开时响一下，让用户知道是什么声音
    }

    private func makeDockIconCard() -> NSView {
        let card = makeCard()

        let title = label("在 Dock 中显示", size: 14, weight: .medium, color: theme.text)
        let desc = label("关闭后 Dock 和 ⌘Tab 里不再出现 Typefree，可从屏幕顶部菜单栏的图标打开。",
                         size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        let toggle = VPToggle(theme: theme, target: self, action: #selector(dockIconChanged(_:)))
        toggle.setOn(DockIcon.isShown, animated: false)
        toggle.setAccessibilityLabel("在 Dock 中显示")

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(toggle)

        mount(row, in: card)
        return card
    }

    @objc private func dockIconChanged(_ sender: VPToggle) {
        DockIcon.setShown(sender.isOn)
        // 切激活策略时系统会把本 App 挪到后台，把设置窗拉回前台，别让用户以为窗口没了
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func mainWindowAppearanceChanged(_ sender: VPSegmentedControl) {
        let option = Self.appearanceOptions[sender.selectedSegment]
        UserDefaults.standard.set(option.rawValue, forKey: MainWindowAppearance.userDefaultsKey)
        NotificationCenter.default.post(name: MainWindowAppearance.didChangeNotification, object: nil)   // 主窗口、问 AI 面板一起换
    }

    @objc private func overlayControlsChanged(_ sender: VPToggle) {
        let mode: OverlayControlsMode = sender.isOn ? .buttons : .classic
        UserDefaults.standard.set(mode.rawValue, forKey: OverlayControlsMode.userDefaultsKey)
    }

    @objc private func asrVersionChanged(_ sender: VPSegmentedControl) {
        let version = Self.asrVersion(forSegment: sender.selectedSegment)
        config.save(values: ["bigasr_version": version.rawValue])
    }

    @objc private func asrProviderChanged(_ sender: VPSegmentedControl) {
        let provider: CloudASRTranscriber.ASRProvider = (sender.selectedSegment == 1) ? .bailian : .volcano
        switch provider {
        case .volcano:
            // 回到火山：之前若就是火山某档则保留，否则用极速版
            let cur = CloudASRTranscriber().currentVersion()
            let v: CloudASRTranscriber.ASRVersion = (cur.provider == .volcano) ? cur : .turbo
            config.save(values: ["bigasr_version": v.rawValue])
        case .bailian:
            config.save(values: ["bigasr_version": "bailian"])
        }
        refreshASRFields(for: provider)
        // 识别服务商变了，优化卡片可能要在「填框」和「已复用」之间切换，刷新一下
        if let seg = polishProviderControl {
            refreshPolishKeyField(for: polishProvider(forSegment: seg.selectedSegment))
        }
    }

    /// 按服务商刷新识别卡片的动态区（Key + 版本/模型），与「语音优化」同一范式。
    private func refreshASRFields(for provider: CloudASRTranscriber.ASRProvider) {
        guard let container = asrKeyContainer else { return }
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }

        switch provider {
        case .volcano:
            let keyField = makeSecureField(config.string(forKey: "bigasr_api_key"))
            keyField.delegate = self
            bigASRAPIKeyField = keyField
            let keyRow = makeFieldRow(label: "API Key", control: keyField, placeholder: "请输入豆包 API Key")
            container.addArrangedSubview(keyRow)
            keyRow.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

            let versionLabel = label("识别版本", size: 12.5, weight: .medium, color: theme.text2)
            let versionSeg = VPSegmentedControl(
                labels: ["极速版", "标准版", "2.0"],
                trackBg: theme.cardAlt, trackBorder: theme.sep,
                selBg: theme.segSelBg, selBorder: theme.sep,
                selText: theme.text, normalText: theme.text2,
                target: self, action: #selector(asrVersionChanged(_:)))
            versionSeg.selectedSegment = Self.asrVersionSegmentIndex(for: CloudASRTranscriber().currentVersion())
            asrVersionControl = versionSeg
            let versionHint = label("极速版略快最稳，三种速度差不多。每个版本送 20 小时免费额度（半年有效），用完可切到下一个。", size: 11.5, weight: .regular, color: theme.text3)
            versionHint.maximumNumberOfLines = 0
            let versionRow = NSStackView()
            versionRow.orientation = .vertical
            versionRow.alignment = .leading
            versionRow.spacing = 5
            versionRow.addArrangedSubview(versionLabel)
            versionRow.addArrangedSubview(versionSeg)
            versionRow.addArrangedSubview(versionHint)
            container.addArrangedSubview(versionRow)
            versionRow.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            versionSeg.widthAnchor.constraint(equalTo: versionRow.widthAnchor).isActive = true

            asrGetKeyButton?.identifier = NSUserInterfaceItemIdentifier(AppLinks.apiKeyGuideURL)

        case .bailian:
            let keyField = makeSecureField(config.string(forKey: "dashscope_api_key"))
            keyField.delegate = self
            bailianKeyField = keyField
            let keyRow = makeFieldRow(label: "DashScope API Key", control: keyField, placeholder: "请输入 DashScope API Key")
            container.addArrangedSubview(keyRow)
            keyRow.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

            let modelHint = label("qwen3-asr-flash 同步快、效果好，但仅支持 5 分钟以内的短音频——录长内容请改用「火山引擎」的 2.0。送 10 小时免费额度（90 天有效，用完会自动扣费，建议去控制台开「用完即停」）。和「语音优化」的通义千问共用一个 Key。", size: 11.5, weight: .regular, color: theme.text3)
            modelHint.maximumNumberOfLines = 0
            container.addArrangedSubview(modelHint)
            modelHint.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

            asrGetKeyButton?.identifier = NSUserInterfaceItemIdentifier("https://bailian.console.aliyun.com/")
        }
    }

    private static func asrProviderSegmentIndex(for provider: CloudASRTranscriber.ASRProvider) -> Int {
        switch provider {
        case .volcano: return 0
        case .bailian: return 1
        }
    }

    private static func asrVersionSegmentIndex(for version: CloudASRTranscriber.ASRVersion) -> Int {
        switch version {
        case .turbo: return 0
        case .standard: return 1
        case .v2: return 2
        case .bailian: return 0
        }
    }

    private static func asrVersion(forSegment index: Int) -> CloudASRTranscriber.ASRVersion {
        switch index {
        case 1: return .standard
        case 2: return .v2
        default: return .turbo
        }
    }

    // MARK: - Page: Model

    private func buildModel(into stack: NSStackView) {
        stack.addArrangedSubview(pageHeader(
            eyebrow: "TYPEFREE / 模型", title: "模型设置",
            sub: "用你自己的 API。语音直连你选的服务商，没有中间商；历史记录只存在你本机。"))
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        // Prepare field instances fresh from config（secret 经 string 路由钥匙串）
        dashscopeAPIKeyField = makeSecureField(config.string(forKey: "dashscope_api_key"))
        arkAPIKeyField = makeSecureField(config.string(forKey: "ark_api_key"))
        // bigASRAPIKeyField / bailianKeyField 由识别卡片按服务商动态创建（refreshASRFields）
        // Persist edits as soon as a field loses focus ("改动即时保存")
        for field in [dashscopeAPIKeyField, arkAPIKeyField] {
            field?.delegate = self
        }

        // 首次/未配置时，顶部一句明确的「最后一步」引导（会员、试用中都不用填 Key，不催）
        if !CloudASRTranscriber().isConfigured() && !LicenseManager.shared.hasActiveMembership() && !TrialManager.shared.isInTrial {
            let callout = makeFirstRunCallout()
            stack.addArrangedSubview(callout)
            stack.setCustomSpacing(14, after: callout)
        }

        // 会员期间走哪条通道：选择权交给用户（有人为了隐私就是要用自己的 Key）
        if LicenseManager.shared.isMember, !LicenseManager.shared.isMemberExpired(), TrialManager.shared.isTrialAvailable {
            let routeCard = makeMemberRouteCard()
            stack.addArrangedSubview(routeCard)
            stack.setCustomSpacing(14, after: routeCard)
        }

        // Tutorial banner
        let tutorial = makeTutorialBanner()
        stack.addArrangedSubview(tutorial)
        stack.setCustomSpacing(12, after: tutorial)

        // 推荐组合横幅：新用户不知道怎么搭时照抄即可（样式与教程横幅同款，墨黑小标签突出）
        let combo = makeRecommendedComboBanner()
        stack.addArrangedSubview(combo)
        stack.setCustomSpacing(20, after: combo)

        // ① 语音识别 + ② 语音优化：左右并列，体现"识别 → 优化"的顺序，也填满横向空间。
        // 每张卡片外套一层"卡片 + 底部弹性占位"，矮卡被拉高时多余高度由占位吸收，内容不被撑开。
        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 16
        let recCard = makeRecognitionCard()
        let polCard = makePolishCard()
        columns.addArrangedSubview(recCard)
        columns.addArrangedSubview(polCard)
        recCard.heightAnchor.constraint(equalTo: polCard.heightAnchor).isActive = true   // 两卡片等高、底部对齐
        stack.addArrangedSubview(columns)
    }

    /// 把卡片顶到列顶部：底部加弹性占位吸收多余高度，避免被另一列拉伸而撑开内容。
    private func wrapTopColumn(_ card: NSView) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 0
        col.distribution = .fill
        col.addArrangedSubview(card)
        let filler = NSView()
        filler.translatesAutoresizingMaskIntoConstraints = false
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        filler.setContentCompressionResistancePriority(.init(1), for: .vertical)
        col.addArrangedSubview(filler)
        card.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        filler.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    /// 会员通道开关：开 = 识别/润色/问 AI 走会员服务，已填的 Key 留着不用；关 = 自己的 Key 优先，没填的项目才走会员。
    private func makeMemberRouteCard() -> NSView {
        let card = makeCard()
        let on = HostedRoute.memberFirst
        let title = label("优先走会员服务", size: 14, weight: .medium, color: theme.text)
        let desc = label(on ? "识别、润色和问 AI 都用我们提供的服务，下面填的 Key 先留着不用。关掉则优先用你自己的 Key。"
                            : "优先用你自己的 Key（内容直连服务商，不经过我们）；没填 Key 的项目才走会员服务。",
                         size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0
        let toggle = VPToggle(theme: theme, target: self, action: #selector(memberRouteChanged(_:)))
        toggle.setOn(on, animated: false)
        toggle.setAccessibilityLabel("优先走会员服务")

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(toggle)
        mount(row, in: card)
        return card
    }

    @objc private func memberRouteChanged(_ sender: VPToggle) {
        config.save(bool: sender.isOn, forKey: HostedRoute.memberFirstConfigKey)
        invalidate(.model, .home)
    }

    private func makeFirstRunCallout() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 11
        card.layer?.setAppearanceBackground(theme.accent.withAlphaComponent(0.12))
        card.translatesAutoresizingMaskIntoConstraints = false

        let title = label("⚡ 最后一步", size: 13, weight: .semibold, color: theme.accent)
        let body = label("填入下面的 API Key，就能开始用了。", size: 12.5, weight: .regular, color: theme.text2)
        body.maximumNumberOfLines = 0

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(body)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 13, left: 16, bottom: 13, right: 16)
        row.addArrangedSubview(textStack)

        mount(row, in: card)
        return card
    }

    /// 「推荐搭配」横幅：墨黑实心小标签 + 加重文字，样式与教程横幅同款卡片。
    private func makeRecommendedComboBanner() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 11
        card.layer?.borderWidth = 1
        card.layer?.setAppearanceBorder(theme.accent.withAlphaComponent(0.35))
        card.layer?.setAppearanceBackground(theme.accentSoft)
        card.translatesAutoresizingMaskIntoConstraints = false

        // 墨黑实心小标签（同 primary 按钮配色）
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 6
        chip.layer?.setAppearanceBackground(theme.accent)
        chip.translatesAutoresizingMaskIntoConstraints = false
        let chipLabel = NSTextField(labelWithString: "推荐搭配")
        chipLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        chipLabel.textColor = theme.onAccent
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipLabel)
        NSLayoutConstraint.activate([
            chipLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 9),
            chipLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -9),
            chipLabel.topAnchor.constraint(equalTo: chip.topAnchor, constant: 4),
            chipLabel.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -4),
        ])

        let text = label("❶ 识别用「火山引擎（豆包）」 ＋ ❷ 优化用「千问 · 自动选择」，不知道怎么选就按这个来。",
                         size: 13, weight: .medium, color: theme.text)
        text.maximumNumberOfLines = 0
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 13, left: 16, bottom: 13, right: 16)
        row.addArrangedSubview(chip)
        row.addArrangedSubview(text)

        mount(row, in: card)
        return card
    }

    private func makeTutorialBanner() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 11
        card.layer?.borderWidth = 1
        card.layer?.setAppearanceBorder(theme.accent.withAlphaComponent(0.35))
        card.layer?.setAppearanceBackground(theme.accentSoft)
        card.translatesAutoresizingMaskIntoConstraints = false

        let text = label("第一次用？跟着图文教程，几分钟拿到火山引擎的 API Key。", size: 13, weight: .regular, color: theme.text2)
        text.maximumNumberOfLines = 0
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let linkBtn = makeLinkButton(title: "看教程 →", urlString: AppLinks.apiKeyGuideURL)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 13, left: 16, bottom: 13, right: 16)
        row.addArrangedSubview(text)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(linkBtn)

        mount(row, in: card)
        return card
    }

    private func makeRecognitionCard() -> NSView {
        let card = makeCard()

        let badge = makeSectionBadge("1")
        let titleLbl = label("语音识别（必填）", size: 15, weight: .semibold, color: theme.text)
        let headRow = NSStackView()
        headRow.orientation = .horizontal
        headRow.alignment = .centerY
        headRow.spacing = 10
        headRow.addArrangedSubview(badge)
        headRow.addArrangedSubview(titleLbl)

        let desc = label("把你说的话转成文字。识别准、支持热词。",
                          size: 12.5, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        // 服务商分段：火山引擎 / 百炼(阿里)
        let providerLabel = label("服务商", size: 12.5, weight: .medium, color: theme.text2)
        let providerSeg = VPSegmentedControl(
            labels: ["火山引擎（豆包）", "百炼（阿里）"],
            trackBg: theme.cardAlt, trackBorder: theme.sep,
            selBg: theme.segSelBg, selBorder: theme.sep,
            selText: theme.text, normalText: theme.text2,
            target: self, action: #selector(asrProviderChanged(_:)))
        let asrProviderNow = CloudASRTranscriber().currentVersion().provider
        providerSeg.selectedSegment = Self.asrProviderSegmentIndex(for: asrProviderNow)
        asrProviderControl = providerSeg
        // 9-15 Ray：识别服务商只留火山，百炼选项隐藏；已经在用百炼的老用户仍能看到分段（好切回来）
        let showASRProviderSeg = asrProviderNow == .bailian

        // 动态区：随服务商切换（火山→Key+版本三选；百炼→DashScope Key+模型说明）
        let keyContainer = NSStackView()
        keyContainer.orientation = .vertical
        keyContainer.alignment = .leading
        keyContainer.spacing = 10
        asrKeyContainer = keyContainer

        let getKey = makeLinkButton(title: "↗ 点此获取密钥", urlString: AppLinks.apiKeyGuideURL)
        asrGetKeyButton = getKey

        // Test row
        let testBtn = VPButton(title: "▷ 测试连接", style: .secondary, size: .regular,
                               theme: theme, target: self, action: #selector(testRecognitionConnection))
        asrTestButton = testBtn

        let result = label("", size: 12.5, weight: .medium, color: theme.text3)
        asrTestResultLabel = result

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let testRow = NSStackView()
        testRow.orientation = .horizontal
        testRow.alignment = .centerY
        testRow.spacing = 10
        testRow.addArrangedSubview(testBtn)
        testRow.addArrangedSubview(result)
        testRow.addArrangedSubview(spacer)

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        inner.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        inner.addArrangedSubview(headRow)
        inner.addArrangedSubview(desc)
        if showASRProviderSeg {
            inner.addArrangedSubview(providerLabel)
            inner.addArrangedSubview(providerSeg)
        }
        inner.addArrangedSubview(keyContainer)
        inner.addArrangedSubview(getKey)
        inner.addArrangedSubview(testRow)
        inner.setCustomSpacing(4, after: headRow)
        inner.setCustomSpacing(14, after: desc)
        if showASRProviderSeg {
            inner.setCustomSpacing(6, after: providerLabel)
            inner.setCustomSpacing(12, after: providerSeg)
        }
        inner.setCustomSpacing(12, after: getKey)

        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        inner.addArrangedSubview(filler)

        // 分段被隐藏时不在视图树里，不能给它挂宽度约束（否则抛异常，整页空白）
        for v in (showASRProviderSeg ? [desc, providerSeg, keyContainer, testRow] : [desc, keyContainer, testRow]) {
            v.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -36).isActive = true
        }

        mount(inner, in: card)
        refreshASRFields(for: CloudASRTranscriber().currentVersion().provider)
        return card
    }

    private func makePolishCard() -> NSView {
        let card = makeCard()

        let badge = makeSectionBadge("2")
        let titleLbl = label("语音优化（可选）", size: 15, weight: .semibold, color: theme.text)
        let headRow = NSStackView()
        headRow.orientation = .horizontal
        headRow.alignment = .centerY
        headRow.spacing = 10
        headRow.addArrangedSubview(badge)
        headRow.addArrangedSubview(titleLbl)

        let desc = label("把识别出的文字整理成通顺、好读的句子（去口水、改口误、自动分段），保留你的口语风格。",
                          size: 12.5, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        // Provider selector: 通义千问 / 豆包 / 不优化（阿里润色更强，作为推荐放最前）
        // 自绘分段控件，软填充观感（详见 VPSegmentedControl）
        let current = config.string(forKey: "polish_provider") ?? "qwen"
        // 9-15 Ray：润色只留「百炼 / 不优化」，豆包隐藏；已经选了豆包的老用户仍显示三段
        polishSegProviders = current == "doubao" ? ["qwen", "doubao", "none"] : ["qwen", "none"]
        let seg = VPSegmentedControl(
            labels: polishSegProviders.map { Self.polishProviderLabel($0) },
            trackBg: theme.cardAlt,
            trackBorder: theme.sep,
            selBg: theme.segSelBg,
            selBorder: theme.sep,
            selText: theme.text,
            normalText: theme.text2,
            target: self,
            action: #selector(polishProviderChanged(_:)))
        seg.selectedSegment = polishSegmentIndex(for: current)
        polishProviderControl = seg

        // Key field container (swapped by selection)
        let keyContainer = NSStackView()
        keyContainer.orientation = .vertical
        keyContainer.alignment = .leading
        keyContainer.spacing = 10
        polishKeyContainer = keyContainer

        let getKey = makeLinkButton(title: "↗ 点此获取密钥", urlString: "https://console.volcengine.com/ark")
        polishGetKeyButton = getKey

        // Test row
        let testBtn = VPButton(title: "▷ 测试连接", style: .secondary, size: .regular,
                               theme: theme, target: self, action: #selector(testPolishConnection))
        polishTestButton = testBtn

        let result = label("", size: 12.5, weight: .medium, color: theme.text3)
        polishTestResultLabel = result

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let testRow = NSStackView()
        testRow.orientation = .horizontal
        testRow.alignment = .centerY
        testRow.spacing = 10
        testRow.addArrangedSubview(testBtn)
        testRow.addArrangedSubview(result)
        testRow.addArrangedSubview(spacer)

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 12
        inner.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        inner.addArrangedSubview(headRow)
        inner.addArrangedSubview(desc)
        inner.addArrangedSubview(seg)
        inner.addArrangedSubview(keyContainer)
        inner.addArrangedSubview(getKey)
        inner.addArrangedSubview(testRow)
        inner.setCustomSpacing(4, after: headRow)
        inner.setCustomSpacing(16, after: desc)
        inner.setCustomSpacing(14, after: seg)
        inner.setCustomSpacing(12, after: getKey)

        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        inner.addArrangedSubview(filler)

        desc.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -36).isActive = true
        keyContainer.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -36).isActive = true
        testRow.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -36).isActive = true

        mount(inner, in: card)

        // Populate the key field / hint for the current selection
        refreshPolishKeyField(for: current)
        return card
    }

    /// 声波品牌标：圆角盒子 + 钟形声波（与 App 图标同款）。小盒(<40)用 3 根、大盒用 5 根；
    /// 深色盒子上波形用浅色(onAccent)。用 CALayer 画实心柱，原生清晰。
    private func makeWaveformMark(box: CGFloat, corner: CGFloat, boxColor: NSColor, waveColor: NSColor) -> NSView {
        // viewBox 0..100 柱子：(x, 宽, y, 高, 圆角)
        let bars5: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (11, 10, 37.2, 25.6, 5), (28, 10, 26, 48, 5), (45, 10, 18, 64, 5),
            (62, 10, 29.2, 41.6, 5), (79, 10, 38.8, 22.4, 5)
        ]
        let bars3: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (10, 18, 30.2, 39.7, 9), (41, 18, 18, 64, 9), (72, 18, 33.4, 33.3, 9)
        ]
        let bars = box < 40 ? bars3 : bars5
        let mark = box * 0.68            // 波形占盒子 68%
        let off = (box - mark) / 2
        let k = mark / 100.0

        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = corner
        v.layer?.setAppearanceBackground(boxColor)
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: box),
            v.heightAnchor.constraint(equalToConstant: box),
        ])
        for (x, w, y, h, r) in bars {
            let bar = CALayer()
            bar.setAppearanceBackground(waveColor)
            // CALayer 默认 y 向上、viewBox y 向下 → 翻转：柱底 = box - off - (y+h)*k
            bar.frame = CGRect(x: off + x*k, y: box - off - (y+h)*k, width: w*k, height: h*k)
            bar.cornerRadius = r*k
            v.layer?.addSublayer(bar)
        }
        return v
    }

    private func makeSectionBadge(_ text: String) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.setAppearanceBackground(theme.accentSoft)
        v.translatesAutoresizingMaskIntoConstraints = false
        let l = label(text, size: 12, weight: .bold, color: theme.accent)
        l.alignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 22),
            v.heightAnchor.constraint(equalToConstant: 22),
            l.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    /// A vertical field: label on top, control below (matches the mockup).
    private func makeFieldRow(label labelText: String, control: NSView, placeholder: String) -> NSView {
        let l = label(labelText, size: 12.5, weight: .medium, color: theme.text2)
        if let field = control as? NSTextField {
            field.placeholderString = placeholder
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        control.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.addArrangedSubview(l)
        stack.addArrangedSubview(control)
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeLinkButton(title: String, urlString: String) -> NSButton {
        let btn = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.contentTintColor = theme.accent
        btn.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let attr = NSMutableAttributedString(string: title)
        attr.addAttribute(.foregroundColor, value: theme.accent, range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                          range: NSRange(location: 0, length: attr.length))
        btn.attributedTitle = attr
        btn.identifier = NSUserInterfaceItemIdentifier(urlString)
        return btn
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 润色分段当前显示的服务商顺序（豆包默认隐藏，见 buildPolishCard）
    private var polishSegProviders: [String] = ["qwen", "none"]

    private static func polishProviderLabel(_ provider: String) -> String {
        switch provider {
        case "doubao": return "火山引擎（豆包）"
        case "none": return "不优化"
        default: return "百炼（阿里）"
        }
    }

    private func polishSegmentIndex(for provider: String) -> Int {
        polishSegProviders.firstIndex(of: provider) ?? 0 // qwen（推荐，放最前）
    }

    private func polishProvider(forSegment index: Int) -> String {
        polishSegProviders.indices.contains(index) ? polishSegProviders[index] : "qwen"
    }

    @objc private func polishProviderChanged(_ sender: VPSegmentedControl) {
        let provider = polishProvider(forSegment: sender.selectedSegment)
        config.save(value: provider, forKey: "polish_provider")
        refreshPolishKeyField(for: provider)
        polishTestResultLabel?.stringValue = ""
        invalidate(.home)
    }

    /// Rebuild the polish key field (or hint) to match the selected provider.
    private func refreshPolishKeyField(for provider: String) {
        guard let container = polishKeyContainer else { return }
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }

        switch provider {
        case "none":
            let hint = label("直接输出识别原文，不做整理。", size: 12.5, weight: .regular, color: theme.text3)
            hint.maximumNumberOfLines = 0
            container.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            polishGetKeyButton?.isHidden = true
            polishTestButton?.isEnabled = false
            polishTestButton?.title = "无需测试"
        case "qwen":
            let rec = label("✓ 推荐。语义润色效果好。", size: 11.5, weight: .medium, color: theme.accent)
            rec.maximumNumberOfLines = 0
            container.addArrangedSubview(rec)
            rec.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            // 识别已用阿里(百炼) key 时，优化复用同一个 DashScope Key，不再出重复输入框
            let asrUsesBailian = CloudASRTranscriber().currentVersion().provider == .bailian
            let dashKey = config.string(forKey: "dashscope_api_key") ?? ""
            if asrUsesBailian && !dashKey.isEmpty {
                let reused = label("✓ 已复用识别填的 DashScope Key，无需重填（同一个阿里 key 通用）。", size: 12, weight: .medium, color: theme.accent)
                reused.maximumNumberOfLines = 0
                container.addArrangedSubview(reused)
                reused.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            } else {
                let row = makeFieldRow(label: "通义千问 API Key", control: dashscopeAPIKeyField!,
                                       placeholder: "请输入 DashScope API Key")
                container.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            }
            let modelRow = makeQwenPolishModelDropdownRow()
            container.addArrangedSubview(modelRow)
            modelRow.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            polishGetKeyButton?.isHidden = false
            polishGetKeyButton?.identifier = NSUserInterfaceItemIdentifier("https://bailian.console.aliyun.com/")
            polishTestButton?.isEnabled = true
            polishTestButton?.title = "▷ 测试连接"
        default: // doubao
            let warn = label("⚠️ 火山引擎（豆包）润色效果一般，建议换「百炼（阿里）」。", size: 11.5, weight: .medium, color: theme.text2)
            warn.maximumNumberOfLines = 0
            container.addArrangedSubview(warn)
            warn.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            let row = makeFieldRow(label: "豆包大模型 API Key", control: arkAPIKeyField!,
                                   placeholder: "请输入豆包大模型 API Key")
            container.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            let modelRow = makePolishModelRow(
                configKey: "doubao_polish_model",
                presets: ["doubao-seed-2-0-pro-260215", "doubao-seed-1-6-flash-250828"],
                caption: "两个模型按需选：doubao-seed-2-0-pro-260215 质量更好（默认）；doubao-seed-1-6-flash-250828 更快，但质量一般。")
            container.addArrangedSubview(modelRow)
            modelRow.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            polishGetKeyButton?.isHidden = false
            polishGetKeyButton?.identifier = NSUserInterfaceItemIdentifier("https://console.volcengine.com/ark")
            polishTestButton?.isEnabled = true
            polishTestButton?.title = "▷ 测试连接"
        }
    }

    /// 润色模型默认值（留空时回落）。
    private func polishModelDefault(forKey key: String) -> String {
        switch key {
        case "qwen_polish_model": return PolishModelRouter.autoValue
        case "doubao_polish_model": return "doubao-seed-2-0-pro-260215"
        default: return ""
        }
    }

    /// 千问润色模型下拉选项：value → 展示名。顺序即下拉框顺序。
    private var qwenPolishModelOptions: [(value: String, title: String)] {
        [(PolishModelRouter.autoValue, "自动 · 质量优先（推荐）"),
         (PolishModelRouter.autoSpeedValue, "自动 · 速度优先"),
         ("qwen3.8-max", "qwen3.8-max · 质量最好"),
         ("qwen3.7-max", "qwen3.7-max · 质量好"),
         ("qwen3.7-flash", "qwen3.7-flash · 快，付费最便宜"),
         ("qwen3.7-plus", "qwen3.7-plus · 均衡"),
         ("qwen3.6-flash", "qwen3.6-flash · 最快")]
    }

    /// 「模型」行（千问专用）：下拉框，首项「自动选择」。
    /// 额度冷却中的模型加「额度可能已用完」标记（标记来自请求层捕捉到的 403）。
    private func makeQwenPolishModelDropdownRow() -> NSView {
        let def = polishModelDefault(forKey: "qwen_polish_model")
        let saved = config.string(forKey: "qwen_polish_model") ?? ""
        let current = saved.isEmpty ? def : saved

        // 9-15 Ray：先别给用户太多选择，这三档隐藏；正选着的仍显示
        let hiddenModels: Set<String> = ["qwen3.8-max", "qwen3.7-max", "qwen3.6-flash"]
        var options = qwenPolishModelOptions.filter { !hiddenModels.contains($0.value) || $0.value == current }
        if !current.isEmpty, !options.contains(where: { $0.value == current }) {
            options.append((current, "自定义：\(current)"))
        }

        let items = options.map { opt -> VPDropdown.Item in
            let exhausted = !PolishModelRouter.isAuto(opt.value) && PolishModelRouter.isExhausted(opt.value)
            return VPDropdown.Item(value: opt.value,
                                   title: exhausted ? opt.title + "（当前不可用）" : opt.title,
                                   warn: exhausted)
        }
        // 白底 + 细边框：与上方 API Key 输入框同款观感（同处「标签下的单值控件」位置）
        // 收起时选中项若已用完 → 红字（此时用户需要动手换）；菜单里其余已用完项只用弱化色，避免满屏红。
        let popup = VPDropdown(items: items, selectedValue: current,
                               trackBg: theme.card,
                               trackBorder: Self.dropdownBorder,
                               textColor: theme.text, chevronColor: theme.text3,
                               warnColor: theme.danger, mutedColor: theme.text3)
        popup.onSelect = { [weak self] value in
            guard let self else { return }
            self.config.save(value: value, forKey: "qwen_polish_model")
            self.polishTestResultLabel?.stringValue = ""
            // 重建本页让状态行跟随新选择。必须延到下一轮 runloop：invalidate 会拆掉
            // 正在执行回调的那个下拉控件所在的视图树，同步拆会在它自己的方法栈上释放它。
            DispatchQueue.main.async { [weak self] in self?.invalidate(.model) }
        }

        let lbl = label("模型", size: 12.5, weight: .medium, color: theme.text2)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.addArrangedSubview(lbl)
        stack.addArrangedSubview(popup)

        // 状态行：自动模式告诉用户「现在在用哪个」；手动选中的模型额度用完则红字给出路。
        if let status = qwenPolishStatusLine(for: current) {
            stack.addArrangedSubview(status)
            status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let cap = label("两种自动模式都会在某个模型免费额度用完时自动换下一个，无需手动切换：质量优先从 3.7-plus 往下用；速度优先从 3.7-flash 开始，说长段话时出字明显更快。每个模型各送 100 万 Token 免费额度；建议在百炼控制台开启「免费额度用完即停」，额度用完 App 才能感知并自动切换。",
                        size: 11.5, weight: .regular, color: theme.text3)
        cap.maximumNumberOfLines = 0
        stack.addArrangedSubview(cap)
        cap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// 模型下拉框下方的状态行；没什么可说时返回 nil。
    /// - 自动模式：显示当前实际会用的模型（用自动的人最关心这个）。
    /// - 手动模式且该模型额度已用完：红字 + 指出路（换「自动选择」）。
    private func qwenPolishStatusLine(for current: String) -> NSTextField? {
        if PolishModelRouter.isAuto(current) {
            guard let inUse = PolishModelRouter.candidates(for: current).first else { return nil }
            let skipped = PolishModelRouter.qualityChain.filter { PolishModelRouter.isExhausted($0) }.count
            let suffix = skipped > 0 ? "（已自动跳过 \(skipped) 个当前不可用的模型）" : ""
            let l = label("当前在用：\(inUse)\(suffix)", size: 11.5, weight: .medium, color: theme.text2)
            l.maximumNumberOfLines = 0
            return l
        }
        guard PolishModelRouter.isExhausted(current) else { return nil }
        // 403 既可能是免费额度用完，也可能是这把 Key 没开通该模型——两种都得换模型，文案一并覆盖。
        let l = label("这个模型当前不可用（免费额度已用完，或这个 Key 未开通它），润色会失败。建议改用「自动 · 质量优先」，会自动换到可用的模型。",
                      size: 11.5, weight: .medium, color: theme.danger)
        l.maximumNumberOfLines = 0
        return l
    }


    /// 「模型」行：复用识别版本的横向分段样式，从预设模型里切换。
    private func makePolishModelRow(configKey: String, presets: [String], caption: String) -> NSView {
        let def = polishModelDefault(forKey: configKey)
        let saved = config.string(forKey: configKey) ?? ""
        let current = saved.isEmpty ? def : saved
        let selected = presets.firstIndex(of: current) ?? (saved.isEmpty ? (presets.firstIndex(of: def) ?? 0) : -1)
        let customModelNotice = (!saved.isEmpty && selected == -1) ? "当前使用：\(current)。它不在上方预设里；点上方任一项才会切换。" : nil
        let modelSeg = VPSegmentedControl(
            labels: presets,
            trackBg: theme.cardAlt,
            trackBorder: theme.sep,
            selBg: theme.segSelBg,
            selBorder: theme.sep,
            selText: theme.text,
            normalText: theme.text2,
            target: self,
            action: #selector(polishModelSegmentChanged(_:)))
        modelSeg.identifier = NSUserInterfaceItemIdentifier(configKey)
        modelSeg.selectedSegment = selected

        let lbl = label("模型", size: 12.5, weight: .medium, color: theme.text2)
        let cap = label(caption, size: 11.5, weight: .regular, color: theme.text3)
        cap.maximumNumberOfLines = 0
        let customNotice = customModelNotice.map {
            label($0, size: 11.5, weight: .medium, color: theme.text2)
        }
        customNotice?.maximumNumberOfLines = 0

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.addArrangedSubview(lbl)
        stack.addArrangedSubview(modelSeg)
        if let customNotice {
            stack.addArrangedSubview(customNotice)
            customNotice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(cap)
        modelSeg.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        cap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    @objc private func polishModelSegmentChanged(_ sender: VPSegmentedControl) {
        guard let key = sender.identifier?.rawValue else { return }
        let presets: [String]
        switch key {
        case "doubao_polish_model":
            presets = ["doubao-seed-2-0-pro-260215", "doubao-seed-1-6-flash-250828"]
        default:
            return
        }
        let index = max(0, min(sender.selectedSegment, presets.count - 1))
        let value = presets[index]
        config.save(value: value, forKey: key)
        polishTestResultLabel?.stringValue = ""
    }

    private func makeAutoLearnCard() -> NSView {
        let card = makeCard()

        // 2026-09-23 实话实说：这个开关实际只管「改过的错词进词库」。原文案说的「日常输入学常用词」9-11 已停、
        // 「表达习惯」只统计没交给润色用过（观察期），不再写进说明。
        let title = label("改过的词自动进词库", size: 14, weight: .medium, color: theme.text)
        let desc = label("识别错的词你改过一次，就会加进词库，下次优先认对。学到时会提示，可以撤销；从词库删掉的词不会再自动加回来。", size: 12, weight: .regular, color: theme.text3)

        let toggle = VPToggle(theme: theme, target: self, action: #selector(autoLearnChanged(_:)))
        toggle.setOn(config.bool(forKey: "term_corrections_auto_learn_enabled", defaultValue: true), animated: false)
        autoLearnCheckbox = toggle

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(toggle)

        mount(row, in: card)
        return card
    }

    private func makeLaunchAtLoginCard() -> NSView {
        let card = makeCard()

        let title = label("开机时自动启动", size: 14, weight: .medium, color: theme.text)
        let desc = label("登录后自动在后台打开 Typefree，不用每次手动启动。", size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        let toggle = VPToggle(theme: theme, target: self, action: #selector(launchAtLoginChanged(_:)))
        toggle.setOn(LaunchAtLogin.isEnabled, animated: false)
        launchAtLoginCheckbox = toggle

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(toggle)

        mount(row, in: card)
        return card
    }

    /// 鼠标长按说话（实验功能）。开关只写配置，监听器每次按下时读取，无需通知重建。
    private func makeMouseHoldToTalkCard() -> NSView {
        let toggle = VPToggle(theme: theme, target: self, action: #selector(mouseHoldToTalkChanged(_:)))
        toggle.setOn(MouseHoldToTalkSettings.isEnabled, animated: false)
        toggle.setAccessibilityLabel("鼠标长按说话")
        return makeExploreCard(id: "mouse", title: "鼠标长按说话",
                               summary: "在输入框里按住鼠标说话，松开后自动输入。", control: toggle, demo: .mouseHold) {
            self.makeExploreHelp("开始说话：在输入框上按住鼠标左键约半秒，松开即结束。\n\n锁定录音：向下拖动，或移到胶囊内及边缘附近。绿光亮起后松手继续说，点 ✓ 完成、× 取消。\n\n拖开取消：按住鼠标拖远，红光亮起后松手取消；移回胶囊可恢复锁定。锁定后，也可重新按住胶囊向外拖动取消。普通移动鼠标不会取消录音。\n\n微信：仅在聊天主窗口底部输入区域的左半部分生效，会接管微信自带的按住语音输入。触控板不建议开启。")
        }
    }

    // MARK: 输出语言

    /// 默认输出语言：不管说什么语言都翻成它。开着时录音胶囊常驻语言标签，说口令可临时切换。
    private func makeDefaultOutputLanguageRow() -> NSView {
        let title = label("默认输出语言", size: 13, weight: .medium, color: theme.text)
        let desc = label("固定翻译成一种语言，或选择跟随说话语言。", size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        var items: [VPDropdown.Item] = [VPDropdown.Item(value: "", title: "跟随说话语言")]
        for language in OutputLanguage.configured() where language.enabled {
            items.append(VPDropdown.Item(value: language.id, title: language.name))
        }
        let current = config.string(forKey: OutputLanguage.defaultConfigKey) ?? ""
        let popup = VPDropdown(items: items, selectedValue: items.contains { $0.value == current } ? current : "",
                               trackBg: theme.card,
                               trackBorder: Self.dropdownBorder,
                               textColor: theme.text, chevronColor: theme.text3)
        popup.onSelect = { [weak self] value in
            self?.config.save(value: value, forKey: OutputLanguage.defaultConfigKey)
        }
        popup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        row.distribution = .fill
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(popup)
        return row
    }

    private func makeOutputLanguageCommandRow() -> NSView {
        let title = label("语音口令", size: 13, weight: .medium, color: theme.text)
        let desc = label("说「用英文」或「翻译成日文」，临时切换本次输出。", size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0
        let master = VPToggle(theme: theme, target: self, action: #selector(outputLanguageCommandEnabledChanged(_:)))
        master.setOn(config.bool(forKey: OutputLanguage.commandEnabledConfigKey, defaultValue: true), animated: false)
        master.setAccessibilityLabel("语音口令")
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        row.distribution = .fill
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(master)
        return row
    }

    /// 语言开关、触发词和添加语言沿用原配置，默认收起。
    private func makeOutputLanguageCommandOptions() -> NSView {
        outputLanguagePhraseFields = [:]
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        let help = makeExploreHelp("在句首或句尾加上口令，这一次就用指定语言输出。句首说完口令后稍停一下。开启固定语言时，胶囊会显示对应语言标签。翻译需要开启 AI 润色。")
        column.addArrangedSubview(help)
        help.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        // 语言：一排小圆片，黑底 = 开着，点一下切换
        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = 8
        let chipLabel = label("语言", size: 12.5, weight: .medium, color: theme.text3)
        chipLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        chips.addArrangedSubview(chipLabel)
        let languages = OutputLanguage.configured()
        for language in languages {
            let chip = VPButton(title: language.name, style: language.enabled ? .primary : .secondary, size: .small, theme: theme,
                                target: self, action: #selector(outputLanguageChipTapped(_:)))
            chip.identifier = NSUserInterfaceItemIdentifier(language.id)
            chip.toolTip = "说「\(language.phrases.first ?? "用" + language.name)」这一句就用\(language.name)输出"
            chips.addArrangedSubview(chip)
        }
        column.addArrangedSubview(chips)

        // 高级：自定义触发词 / 添加语言，默认收起
        let disclosure = VPButton(title: outputLanguageAdvancedExpanded ? "收起自定义触发词" : "自定义触发词…", style: .secondary, size: .small, theme: theme,
                                  target: self, action: #selector(outputLanguageAdvancedToggled))
        column.addArrangedSubview(disclosure)

        if outputLanguageAdvancedExpanded {
            for language in languages {
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 10
                let name = label(language.name, size: 12.5, weight: .medium, color: theme.text2)
                name.widthAnchor.constraint(equalToConstant: 64).isActive = true
                let field = makeTextField(language.phrases.joined(separator: "，"))
                field.font = .systemFont(ofSize: 12)
                field.placeholderString = "触发词，用逗号分隔"
                field.identifier = NSUserInterfaceItemIdentifier("olang:" + language.id)
                field.delegate = self
                field.setContentHuggingPriority(.defaultLow, for: .horizontal)
                outputLanguagePhraseFields[language.id] = field
                row.addArrangedSubview(name)
                row.addArrangedSubview(field)
                if !language.isBuiltin {
                    let remove = VPButton(title: "移除", style: .secondary, size: .small, theme: theme,
                                          target: self, action: #selector(outputLanguageRemoveTapped(_:)))
                    remove.identifier = NSUserInterfaceItemIdentifier(language.id)
                    row.addArrangedSubview(remove)
                }
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }

            let addRow = NSStackView()
            addRow.orientation = .horizontal
            addRow.alignment = .centerY
            addRow.spacing = 10
            let addLabel = label("添加语言", size: 12.5, weight: .medium, color: theme.text3)
            addLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let nameField = makeTextField("")
            nameField.font = .systemFont(ofSize: 12)
            nameField.placeholderString = "语言名，如 泰语"
            nameField.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let phrasesField = makeTextField("")
            phrasesField.font = .systemFont(ofSize: 12)
            phrasesField.placeholderString = "触发词，不填则用「用泰语、翻译成泰语」"
            phrasesField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let addButton = VPButton(title: "添加", style: .secondary, size: .small, theme: theme,
                                     target: self, action: #selector(outputLanguageAddTapped))
            outputLanguageAddNameField = nameField
            outputLanguageAddPhrasesField = phrasesField
            addRow.addArrangedSubview(addLabel)
            addRow.addArrangedSubview(nameField)
            addRow.addArrangedSubview(phrasesField)
            addRow.addArrangedSubview(addButton)
            column.addArrangedSubview(addRow)
            addRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        return column
    }

    @objc private func outputLanguageCommandEnabledChanged(_ sender: VPToggle) {
        config.save(bool: sender.isOn, forKey: OutputLanguage.commandEnabledConfigKey)
    }

    @objc private func outputLanguageChipTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var list = OutputLanguage.configured()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].enabled.toggle()
        OutputLanguage.save(list)
        // 默认语言被关掉了 → 回到跟随
        if !list[index].enabled, config.string(forKey: OutputLanguage.defaultConfigKey) == id {
            config.save(value: "", forKey: OutputLanguage.defaultConfigKey)
        }
        invalidate(.explore)
    }

    @objc private func outputLanguageAdvancedToggled() {
        outputLanguageAdvancedExpanded.toggle()
        invalidate(.explore)
    }

    private func saveOutputLanguagePhrases(id: String, text: String) {
        var list = OutputLanguage.configured()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let phrases = OutputLanguage.parsePhrases(text)
        guard phrases != list[index].phrases else { return }
        list[index].phrases = phrases
        OutputLanguage.save(list)
    }

    @objc private func outputLanguageRemoveTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var list = OutputLanguage.configured()
        list.removeAll { $0.id == id }
        OutputLanguage.save(list)
        if config.string(forKey: OutputLanguage.defaultConfigKey) == id {
            config.save(value: "", forKey: OutputLanguage.defaultConfigKey)
        }
        invalidate(.explore)
    }

    @objc private func outputLanguageAddTapped() {
        let name = (outputLanguageAddNameField?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var phrases = OutputLanguage.parsePhrases(outputLanguageAddPhrasesField?.stringValue ?? "")
        if phrases.isEmpty { phrases = ["用\(name)", "翻译成\(name)", "翻成\(name)", "\(name)输出"] }
        var list = OutputLanguage.configured()
        list.append(OutputLanguage.makeCustom(name: name, phrases: phrases))
        OutputLanguage.save(list)
        invalidate(.explore)
    }

    private func makeHotkeyBehaviorCard() -> NSView {
        let card = makeCard()

        let title = label("单击快捷键开始/停止录音", size: 14, weight: .medium, color: theme.text)
        let desc = label("开启后，仍可长按录音；短按一次会保持录音，再短按一次结束。", size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        let toggle = VPToggle(theme: theme, target: self, action: #selector(tapToggleChanged(_:)))
        toggle.setOn(RecordingHotkeyBehavior.isTapToggleEnabled, animated: false)
        tapToggleCheckbox = toggle

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(toggle)

        mount(row, in: card)
        return card
    }

    private func makeAudioCard() -> NSView {
        let card = makeCard()
        let mgr = MicrophoneManager.shared

        let l = label("麦克风", size: 14, weight: .medium, color: theme.text)
        let s = label("选择录音用的麦克风。如果没有声音输入，可以试试切换。", size: 12, weight: .regular, color: theme.text3)
        s.maximumNumberOfLines = 0
        s.preferredMaxLayoutWidth = 320

        let currentLbl = label(mgr.displayName(), size: 13, weight: .regular, color: theme.text2)
        currentLbl.alignment = .right
        currentLbl.maximumNumberOfLines = 1
        currentLbl.lineBreakMode = .byTruncatingTail
        currentLbl.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let chevron = label("›", size: 18, weight: .regular, color: theme.text3)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(l)
        textStack.addArrangedSubview(s)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let rightStack = NSStackView()
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 6
        rightStack.addArrangedSubview(currentLbl)
        rightStack.addArrangedSubview(chevron)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(rightStack)

        let click = NSClickGestureRecognizer(target: self, action: #selector(openMicrophonePicker))
        row.addGestureRecognizer(click)

        mount(row, in: card)
        return card
    }

    @objc private func openMicrophonePicker() {
        guard let host = window else { return }
        let picker = MicrophonePickerSheet(theme: theme)
        activeMicrophonePicker = picker
        picker.present(over: host) { [weak self] in
            self?.invalidate(.settings)
            self?.activeMicrophonePicker = nil
        }
    }

    private func makePermissionsCard() -> NSView {
        let card = makeCard()
        let micInfo = micStatusInfo()
        let accessOK = AXIsProcessTrusted()
        let rows: [(String, String, Selector)] = [
            ("麦克风", micInfo.ok ? "已允许，可录音" : "未允许，请到系统设置开启", #selector(openMicrophoneSettings)),
            ("辅助功能", accessOK ? "已允许，可自动粘贴" : "未允许，只能复制到剪贴板", #selector(openAccessibilitySettings)),
        ]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for (i, r) in rows.enumerated() {
            stack.addArrangedSubview(makePermissionRow(label: r.0, sub: r.1, action: r.2))
            if i < rows.count - 1 {
                stack.addArrangedSubview(makeHairline(insetH: 18))
            }
        }
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        mount(stack, in: card)
        return card
    }

    private func makePermissionRow(label labelText: String, sub: String, action: Selector) -> NSView {
        let l = label(labelText, size: 14, weight: .medium, color: theme.text)
        let s = label(sub, size: 12, weight: .regular, color: theme.text3)
        s.maximumNumberOfLines = 0
        s.lineBreakMode = .byWordWrapping
        let btn = VPButton(title: "系统设置 →", style: .secondary, size: .small,
                           theme: theme, target: self, action: action)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(l)
        textStack.addArrangedSubview(s)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        s.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        btn.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(textStack)
        row.addSubview(btn)
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            textStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 16),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -16),
            textStack.trailingAnchor.constraint(equalTo: btn.leadingAnchor, constant: -12),
            btn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            btn.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    /// Persist the model-tab field values to the local config file.
    /// Drops zhipu_api_key entirely; leaves any existing stored value for that key untouched.
    private func persistModelFields() {
        // 各家 API Key 直接走 saveSecret（写钥匙串 + 校验）；field 为 nil 时不动，避免清空已存的 key。
        // 空字符串 = 删除该 key；saveSecret 失败（钥匙串写不进）则提示重试，不静默成功。
        var secretOK = true
        if let f = bigASRAPIKeyField {
            secretOK = config.saveSecret(f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "bigasr_api_key") && secretOK
        }
        if let f = arkAPIKeyField {
            secretOK = config.saveSecret(f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ark_api_key") && secretOK
        }
        // DashScope Key 在识别(百炼)和优化(通义千问)共用同一 config key，取两处非空的
        let dsBailian = bailianKeyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dsPolish = dashscopeAPIKeyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bailianKeyField != nil || dashscopeAPIKeyField != nil {
            secretOK = config.saveSecret(!dsBailian.isEmpty ? dsBailian : dsPolish, forKey: "dashscope_api_key") && secretOK
        }
        config.save(values: ["polish_provider": polishProviderControl.map { polishProvider(forSegment: $0.selectedSegment) } ?? "qwen"])
        if !secretOK {
            presentHistoryActionResult(success: false, message: "API Key 保存到钥匙串失败，请重试")
        }
        // 首页"语音识别 / AI 润色"健康卡依赖这些配置
        invalidate(.home)
    }

    @objc private func testRecognitionConnection() {
        persistModelFields()
        asrTestButton?.isEnabled = false
        asrTestResultLabel?.textColor = theme.text3
        asrTestResultLabel?.stringValue = "测试中…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let silence = [Float](repeating: 0, count: 4800) // ~0.3s @16k
            CloudASRTranscriber().transcribe(samples: silence, sampleRate: 16000) { result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.asrTestButton?.isEnabled = true
                    switch result {
                    case .success:
                        self.setTestResult(self.asrTestResultLabel, ok: true, text: "✓ 连接成功")
                    case .failure(let error):
                        // 只有服务端明确判"静音/无语音"（火山 20000003 / 百炼空结果）才算通过——
                        // 说明鉴权、服务开通、网络全链路都通了，只是我们发的确实是静音。
                        // 其它一律如实报错。以前把"非鉴权错误"都当"凭证有效"，
                        // 结果账号没开通极速版（45000030 resource not granted）也显示 ✓，用户真录音才红框。
                        if case CloudASRTranscriber.TranscriptionError.noSpeech? = error as? CloudASRTranscriber.TranscriptionError {
                            self.setTestResult(self.asrTestResultLabel, ok: true, text: "✓ 连接成功")
                        } else {
                            self.setTestResult(self.asrTestResultLabel, ok: false,
                                               text: "✗ " + Self.shortError(error))
                        }
                    }
                }
            }
        }
    }

    @objc private func testPolishConnection() {
        let provider = polishProviderControl.map { polishProvider(forSegment: $0.selectedSegment) } ?? "qwen"
        guard provider != "none" else { return }
        persistModelFields()
        polishTestButton?.isEnabled = false
        polishTestResultLabel?.textColor = theme.text3
        polishTestResultLabel?.stringValue = "测试中…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            AIPolisher().polishCloudASROutput(text: "测试") { result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.polishTestButton?.isEnabled = true
                    switch result {
                    case .success:
                        self.setTestResult(self.polishTestResultLabel, ok: true, text: "✓ 连接成功")
                    case .failure(let error):
                        self.setTestResult(self.polishTestResultLabel, ok: false,
                                           text: "✗ " + Self.shortError(error))
                    }
                }
            }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if let id = field.identifier?.rawValue, id.hasPrefix("olang:") {
            saveOutputLanguagePhrases(id: String(id.dropFirst(6)), text: field.stringValue)
            return
        }
        // 识别(百炼)与优化(通义千问)的 DashScope Key 框联动，保持一致
        if field === bailianKeyField {
            dashscopeAPIKeyField?.stringValue = field.stringValue
            // 识别百炼填了 key → 优化通义千问那边切到「已复用」
            DispatchQueue.main.async { [weak self] in
                guard let self, let seg = self.polishProviderControl else { return }
                self.refreshPolishKeyField(for: polishProvider(forSegment: seg.selectedSegment))
            }
        } else if field === dashscopeAPIKeyField {
            bailianKeyField?.stringValue = field.stringValue
        }
        let modelFields: [NSTextField?] = [bigASRAPIKeyField, bailianKeyField,
                                           dashscopeAPIKeyField, arkAPIKeyField]
        guard modelFields.contains(where: { $0 === field }) else { return }
        persistModelFields()
    }

    private func setTestResult(_ label: NSTextField?, ok: Bool, text: String) {
        label?.textColor = ok ? theme.ok : theme.danger
        label?.stringValue = text
    }

    private static func errorMessage(_ error: Error) -> String {
        if let local = error as? LocalizedError, let desc = local.errorDescription {
            return desc
        }
        return error.localizedDescription
    }

    private static func shortError(_ error: Error) -> String {
        let msg = errorMessage(error)
        if msg.count > 60 { return String(msg.prefix(60)) + "…" }
        return msg
    }

    @objc private func autoLearnChanged(_ sender: VPToggle) {
        config.save(bool: sender.isOn, forKey: "term_corrections_auto_learn_enabled")
    }

    @objc private func mouseHoldToTalkChanged(_ sender: VPToggle) {
        config.save(bool: sender.isOn, forKey: MouseHoldToTalkSettings.enabledKey)
    }

    @objc private func mouseHoldAskChanged(_ sender: VPToggle) {
        config.save(bool: sender.isOn, forKey: MouseHoldToTalkSettings.askEnabledKey)
    }

    /// 长按问 AI：在正文、空白处长按 → 问题交给 AI，答案弹在旁边
    private func makeMouseHoldAskCard() -> NSView {
        let toggle = VPToggle(theme: theme, target: self, action: #selector(mouseHoldAskChanged(_:)))
        toggle.setOn(MouseHoldToTalkSettings.isAskEnabled, animated: false)
        toggle.setAccessibilityLabel("随时问 AI")
        return makeExploreCard(id: "ask", title: "随时问 AI",
                               summary: "在空白处按住说话，让 AI 帮你解答。", control: toggle, demo: .ask) {
            self.makeExploreHelp("开始提问：在页面空白处按住鼠标左键说出问题，松开后显示回答。输入框、按钮和链接不触发提问。\n\n继续追问：按住回答面板继续说话，AI 会结合当前话题回答。\n\n管理浮窗：点图钉可固定回答；未固定时，点外面会收起，鼠标移回可展开。回答支持复制。\n\n查看记录：对话保存在「历史记录」中，同一话题的多轮问答合并展示。\n\n所用模型：使用「模型」中配置的润色模型；千问支持联网搜索。")
        }
    }

    @objc private func tapToggleChanged(_ sender: VPToggle) {
        config.save(bool: sender.isOn, forKey: RecordingHotkeyBehavior.tapToggleConfigKey)
        NotificationCenter.default.post(name: .voicePolishHotkeyDidChange, object: nil)
        invalidate(.home)
    }

    @objc private func launchAtLoginChanged(_ sender: VPToggle) {
        let ok = LaunchAtLogin.setEnabled(sender.isOn)
        // 以系统真实状态回填开关：万一注册/注销失败，开关自动弹回真实状态，不给用户错觉。
        if !ok {
            sender.setOn(LaunchAtLogin.isEnabled, animated: true)
        }
    }

    @objc private func openAccessibilitySettings() {
        settingsDelegate?.openAccessibilitySettings()
    }

    @objc private func openMicrophoneSettings() {
        settingsDelegate?.openMicrophoneSettings()
    }

    // MARK: - Page: History

    private func buildHistory(into stack: NSStackView) {
        allHistoryEntries = historyStore.load(limit: 500)
        historyEntries = allHistoryEntries
        historyVisibleCount = 0
        historyFooter = nil
        cardActionContainers.removeAll()
        cardOutputLabels.removeAll()
        cardViews.removeAll()
        processingIndex = nil

        let header = makePageHeaderRow(
            eyebrow: "TYPEFREE / 历史记录",
            title: "历史记录",
            sub: "文字与音频都只存在本机，没有中间商。重新转写会把音频发送到你配置的识别服务商并产生费用。",
            buttonTitle: "清空历史",
            buttonStyle: .danger,
            buttonAction: #selector(clearHistory),
            secondaryTitle: "导出…",
            secondaryAction: #selector(exportHistory)
        )
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(14, after: header)

        let retentionCard = makeHistoryRetentionCard()
        stack.addArrangedSubview(retentionCard)
        stack.setCustomSpacing(20, after: retentionCard)

        if allHistoryEntries.isEmpty {
            // 文件里有记录、却一条都解不开：多半是钥匙串读不出解密钥匙（工单 #1034）。
            // 原先也显示「还没有历史记录」，用户以为记录全丢了，可能顺手点「清空历史」把能找回的记录删掉。
            let stored = quickHistoryLineCount()
            if stored > 0 {
                let keyReadable = HistoryCrypto.defaultEncryptor() != nil
                delegate.debugLog("[history] \(stored) stored entries, none readable (key readable=\(keyReadable))")
                stack.addArrangedSubview(makeEmptyState(keyReadable
                    ? "有 \(stored) 条历史记录暂时读不出来（解密钥匙可能已更换）。记录还在本机，请不要清空历史，可以在「反馈」里联系我们。"
                    : "有 \(stored) 条历史记录暂时读不出来：没能从系统「钥匙串」取到解密钥匙。记录都还在，请不要清空历史。\n重启电脑后打开 Typefree，系统询问时输入开机密码并点「始终允许」。"))
                return
            }
            stack.addArrangedSubview(makeEmptyState("还没有历史记录。完成一次语音输入后，这里会显示最近的转写结果。"))
            return
        }

        historyContentStack = stack
        appendNextHistoryBatch()
    }

    private func appendNextHistoryBatch() {
        guard let stack = historyContentStack else { return }
        let start = historyVisibleCount
        let end = min(start + historyBatchSize, allHistoryEntries.count)
        guard start < end else { return }

        // remove old footer first
        historyFooter?.removeFromSuperview()
        historyFooter = nil

        var i = start
        var last = end
        while i < last {
            let entry = allHistoryEntries[i]
            if entry.isAsk {
                // 问 AI：同一话题的多轮（相邻、thread 相同）合并成一张卡，允许跨过本批边界
                var group = [i]
                var j = i + 1
                while j < allHistoryEntries.count, allHistoryEntries[j].isAsk, allHistoryEntries[j].thread == entry.thread, entry.thread != nil {
                    group.append(j); j += 1
                }
                let card = makeAskHistoryCard(indices: group)
                stack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                for g in group { cardViews[g] = card }
                i = j
                last = max(last, j)
            } else {
                let card = makeHistoryCard(entry: entry, index: i)
                stack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                cardViews[i] = card
                i += 1
            }
        }
        historyVisibleCount = last

        if historyVisibleCount < allHistoryEntries.count {
            let footer = makeHistoryFooter()
            stack.addArrangedSubview(footer)
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            historyFooter = footer
        }
    }

    private func makeHistoryFooter() -> NSView {
        let v = NSView()
        let l = label("已显示 \(historyVisibleCount) / \(allHistoryEntries.count) · 继续向下滚动加载更多",
                       size: 11, weight: .regular, color: theme.text3)
        l.alignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
            l.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            l.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 16),
            l.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
        ])
        return v
    }

    private func makeHistoryCard(entry: AIPolisher.PolishLog, index: Int) -> NSView {
        let card = makeCard()

        let time = label(formatHistoryTime(entry.time), size: 12, weight: .regular, color: theme.text3)
        let appPill = makePill(text: entry.app)
        let isProcessing = (index == processingIndex)

        // 弹性占位：吸收多余宽度，把右侧内容顶到最右
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [time, appPill] {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        // 右侧操作区：可就地在「按钮」与「转圈」之间切换，不重建整页
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        cardActionContainers[index] = actions
        fillHistoryActions(actions, index: index, processing: isProcessing)

        let metaRow = NSStackView()
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.distribution = .fill
        metaRow.spacing = 8
        metaRow.addArrangedSubview(time)
        metaRow.addArrangedSubview(appPill)
        metaRow.addArrangedSubview(spacer)
        metaRow.addArrangedSubview(actions)

        // 处理中时正文暗显，提示"正在基于这条重做"。空记录（没录到音频 / 识别为空）显示灰色占位。
        let isEmptyEntry = entry.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let output = makeWrappingLabel(
            isEmptyEntry ? "无内容" : entry.output,
            size: 14, weight: .regular,
            color: (isProcessing || isEmptyEntry) ? theme.text3 : theme.text)
        cardOutputLabels[index] = output

        // 只在润色发生时（输出 != 原文）显示原文，避免重复
        let polished = entry.output.trimmingCharacters(in: .whitespacesAndNewlines)
            != entry.asr.trimmingCharacters(in: .whitespacesAndNewlines)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.addArrangedSubview(metaRow)
        stack.addArrangedSubview(output)
        stack.setCustomSpacing(12, after: output)

        var widthConstrainedViews: [NSView] = [metaRow, output]

        if polished {
            let dashed = DashedDivider()
            dashed.color = theme.sep
            dashed.translatesAutoresizingMaskIntoConstraints = false
            dashed.heightAnchor.constraint(equalToConstant: 1).isActive = true

            let asr = makeWrappingLabel("原文 · " + entry.asr, size: 12, weight: .regular, color: theme.text3, mono: true)

            stack.addArrangedSubview(dashed)
            stack.addArrangedSubview(asr)
            stack.setCustomSpacing(8, after: dashed)
            widthConstrainedViews.append(contentsOf: [dashed, asr])
        }

        for v in widthConstrainedViews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        mount(stack, in: card)
        return card
    }

    /// 问 AI 的一段对话（一到多轮）：时间 · 「问 AI」· 所在 App；正文按轮次排：问题（蓝色小竖条）+ 回答（纯文本）
    /// indices 为 allHistoryEntries 里从新到旧的下标，展示时按时间正序
    private func makeAskHistoryCard(indices: [Int]) -> NSView {
        let card = makeCard()
        let newest = allHistoryEntries[indices[0]]
        let turns = indices.reversed().map { allHistoryEntries[$0] }

        let time = label(formatHistoryTime(newest.time), size: 12, weight: .regular, color: theme.text3)
        let askPill = makePill(text: turns.count > 1 ? "问 AI · \(turns.count) 轮" : "问 AI")
        let appPill = makePill(text: newest.app)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [time, askPill, appPill] {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let copy = VPButton(title: "复制回答", style: .secondary, size: .small,
                            theme: theme, target: self, action: #selector(copyAskAnswer(_:)))
        copy.tag = indices[0]
        let more = VPButton(title: "···", style: .icon, size: .small,
                            theme: theme, target: self, action: #selector(showAskHistoryActions(_:)))
        more.tag = indices[0]
        for v in [copy, more] {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let metaRow = NSStackView(views: [time, askPill, appPill, spacer, copy, more])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.distribution = .fill
        metaRow.spacing = 8

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.addArrangedSubview(metaRow)
        stack.setCustomSpacing(14, after: metaRow)
        var widthConstrained: [NSView] = [metaRow]

        let askBlue = NSColor(red: 0.25, green: 0.52, blue: 1.0, alpha: 1)
        for (k, turn) in turns.enumerated() {
            // 问题：左侧 3pt 蓝色竖条（与回答面板同款）
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.setAppearanceBackground(askBlue)
            bar.layer?.cornerRadius = 1.5
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
            let q = makeWrappingLabel(turn.asr, size: 14, weight: .semibold, color: theme.text)
            let qRow = NSStackView(views: [bar, q])
            qRow.orientation = .horizontal
            qRow.alignment = .top
            qRow.spacing = 10
            bar.heightAnchor.constraint(equalTo: qRow.heightAnchor).isActive = true
            stack.addArrangedSubview(qRow)
            stack.setCustomSpacing(8, after: qRow)
            q.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40 - 13).isActive = true

            let plain = AnswerPanel.plainText(fromMarkdown: turn.output)
            let a = makeWrappingLabel(plain.isEmpty ? "（没有回答）" : plain, size: 13.5, weight: .regular,
                                      color: plain.isEmpty ? theme.text3 : theme.text2)
            stack.addArrangedSubview(a)
            widthConstrained.append(a)
            if k < turns.count - 1 { stack.setCustomSpacing(18, after: a) }
        }
        for v in widthConstrained {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        mount(stack, in: card)
        return card
    }

    /// 同一话题（thread）的全部记录下标
    private func askThreadIndices(containing index: Int) -> [Int] {
        guard allHistoryEntries.indices.contains(index) else { return [] }
        let e = allHistoryEntries[index]
        guard e.isAsk, let t = e.thread else { return [index] }
        return allHistoryEntries.indices.filter { allHistoryEntries[$0].isAsk && allHistoryEntries[$0].thread == t }
    }

    @objc private func copyAskAnswer(_ sender: NSButton) {
        guard allHistoryEntries.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AnswerPanel.plainText(fromMarkdown: allHistoryEntries[sender.tag].output), forType: .string)
    }

    @objc private func showAskHistoryActions(_ sender: NSButton) {
        let i = sender.tag
        guard allHistoryEntries.indices.contains(i) else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ sel: Selector) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.tag = i
            menu.addItem(it)
        }
        add("复制问题", #selector(copyAskQuestion(_:)))
        add("复制整段对话", #selector(copyAskThread(_:)))
        menu.addItem(.separator())
        add("删除这段对话", #selector(deleteAskThread(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func copyAskQuestion(_ sender: NSMenuItem) {
        guard allHistoryEntries.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allHistoryEntries[sender.tag].asr, forType: .string)
    }

    @objc private func copyAskThread(_ sender: NSMenuItem) {
        let turns = askThreadIndices(containing: sender.tag).reversed().map { allHistoryEntries[$0] }
        guard !turns.isEmpty else { return }
        let text = turns.map { "问：\($0.asr)\n\n\(AnswerPanel.plainText(fromMarkdown: $0.output))" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func deleteAskThread(_ sender: NSMenuItem) {
        let indices = askThreadIndices(containing: sender.tag)
        guard !indices.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = indices.count > 1 ? "删除这段对话？" : "删除这条问答？"
        alert.informativeText = indices.count > 1 ? "这段对话共 \(indices.count) 轮，会一起删除，无法恢复。" : "无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for i in indices { _ = historyStore.deleteEntry(matching: allHistoryEntries[i]) }
        rebuildSidebar()
        invalidate(.history)
    }

    /// 填充某条卡片右侧操作区：处理中显示转圈+文案，否则显示「复制输出」「···」。
    private func fillHistoryActions(_ actions: NSStackView, index: Int, processing: Bool) {
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if processing {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.widthAnchor.constraint(equalToConstant: 15).isActive = true
            spinner.heightAnchor.constraint(equalToConstant: 15).isActive = true
            spinner.startAnimation(nil)
            let working = label(historyProcessingLabel, size: 12, weight: .medium, color: theme.accent)
            working.setContentHuggingPriority(.required, for: .horizontal)
            actions.addArrangedSubview(spinner)
            actions.addArrangedSubview(working)
        } else {
            let copy = VPButton(title: "复制输出", style: .secondary, size: .small,
                                theme: theme, target: self, action: #selector(copyHistoryOutput(_:)))
            copy.tag = index

            let more = VPButton(title: "···", style: .icon, size: .small,
                                theme: theme, target: self, action: #selector(showHistoryActions(_:)))
            more.tag = index

            for v in [copy, more] {
                v.setContentHuggingPriority(.required, for: .horizontal)
                v.setContentCompressionResistancePriority(.required, for: .horizontal)
            }
            actions.addArrangedSubview(copy)
            actions.addArrangedSubview(more)
        }
    }

    /// 开始就地处理：只更新那条卡片（转圈 + 正文暗显），不重建整页、不跳动。
    private func beginInlineProcessing(index: Int, label labelText: String) {
        processingIndex = index
        historyProcessingLabel = labelText
        if let actions = cardActionContainers[index] {
            fillHistoryActions(actions, index: index, processing: true)
        }
        cardOutputLabels[index]?.textColor = theme.text3
    }

    /// 结束就地处理：恢复按钮 + 用最新文本刷新正文（重新润色用，结构不变）。
    private func endInlineProcessingRepolish(index: Int) {
        processingIndex = nil
        allHistoryEntries = historyStore.load(limit: 500)
        historyEntries = allHistoryEntries
        if allHistoryEntries.indices.contains(index) {
            cardOutputLabels[index]?.stringValue = allHistoryEntries[index].output
        }
        cardOutputLabels[index]?.textColor = theme.text
        if let actions = cardActionContainers[index] {
            fillHistoryActions(actions, index: index, processing: false)
        }
    }

    @objc private func copyHistoryOutput(_ sender: NSButton) {
        guard historyEntries.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(historyEntries[sender.tag].output, forType: .string)
        // 按钮短暂变成「✓ 已复制」，让人知道确实复制上了（以前点了没任何反应，工单 #1049）
        let original = sender.title
        guard original != Self.copiedButtonTitle else { return }
        if !sender.constraints.contains(where: { $0.firstAttribute == .width && $0.secondItem == nil }) {
            sender.widthAnchor.constraint(equalToConstant: sender.frame.width).isActive = true   // 换字时宽度不跳
        }
        sender.title = Self.copiedButtonTitle
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
            guard let sender, sender.title == Self.copiedButtonTitle else { return }
            sender.title = original
        }
    }

    private static let copiedButtonTitle = "✓ 已复制"

    // MARK: - 历史条目操作（播放 / 导出 / 重润色 / 重转写 / 删除）

    @objc private func showHistoryActions(_ sender: NSButton) {
        let i = sender.tag
        guard allHistoryEntries.indices.contains(i) else { return }
        let hasAudio = audioStore.exists(allHistoryEntries[i].audioFile)
        let hasText = !allHistoryEntries[i].asr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ sel: Selector, enabled: Bool) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.tag = i
            it.isEnabled = enabled
            menu.addItem(it)
        }
        // 单一「重试」：有音频→完整重跑(识别+润色，也能救回识别失败的录音)；无音频但有文字→基于已有文字重新润色。
        // 润色用的是已识别的文字、不需要音频，所以"无音频有文字"也能重试；两者都没有（空/静音记录）则无从下手，禁用。
        // 合并 重新润色/重新转写 两个入口，符合"一个重试按钮"的直觉，用户不必理解两者区别。
        let retrySel: Selector = hasAudio ? #selector(retranscribeHistoryEntry(_:)) : #selector(repolishHistoryEntry(_:))
        add("重试", retrySel, enabled: hasAudio || hasText)
        let hasOutput = !allHistoryEntries[i].output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        add("编辑文字…", #selector(editHistoryEntry(_:)), enabled: hasOutput || hasText)
        menu.addItem(.separator())
        add("导出音频…", #selector(exportHistoryAudio(_:)), enabled: hasAudio)
        menu.addItem(.separator())
        add("删除这条", #selector(deleteHistoryEntry(_:)), enabled: true)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func playHistoryAudio(_ sender: NSMenuItem) {
        guard allHistoryEntries.indices.contains(sender.tag),
              let audioFile = allHistoryEntries[sender.tag].audioFile else { return }
        let url = audioStore.url(forFileName: audioFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentHistoryActionResult(success: false, message: "音频已不存在。"); return
        }
        do {
            guard let data = audioStore.loadData(fileName: audioFile) else {
                presentHistoryActionResult(success: false, message: "无法读取音频。")
                return
            }
            let player = try AVAudioPlayer(data: data)
            historyAudioPlayer = player
            player.play()
        } catch {
            presentHistoryActionResult(success: false, message: "无法播放音频。")
        }
    }

    @objc private func exportHistoryAudio(_ sender: NSMenuItem) {
        guard allHistoryEntries.indices.contains(sender.tag),
              let audioFile = allHistoryEntries[sender.tag].audioFile else { return }
        let src = audioStore.url(forFileName: audioFile)
        guard FileManager.default.fileExists(atPath: src.path) else {
            presentHistoryActionResult(success: false, message: "音频已不存在。"); return
        }
        guard let data = audioStore.loadData(fileName: audioFile) else {
            presentHistoryActionResult(success: false, message: "无法读取音频。")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Typefree-\(allHistoryEntries[sender.tag].time.replacingOccurrences(of: ":", with: "-")).m4a"
        panel.begin { resp in
            guard resp == .OK, let dst = panel.url else { return }
            try? FileManager.default.removeItem(at: dst)
            try? data.write(to: dst, options: .atomic)
        }
    }

    /// 就地编辑整理稿：保存进历史，并把"用户改了什么"静默喂给纠错学习——
    /// 这是自动学习最可靠的信号源（发生在自己 App 里，百分之百观察得到）。
    @objc private func editHistoryEntry(_ sender: NSMenuItem) {
        guard processingIndex == nil else { return }
        let index = sender.tag
        guard allHistoryEntries.indices.contains(index) else { return }
        let entry = allHistoryEntries[index]
        let polished = entry.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = polished.isEmpty ? entry.asr.trimmingCharacters(in: .whitespacesAndNewlines) : entry.output
        guard !original.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "编辑这条记录"
        alert.informativeText = "改动会保存进历史；改过的词会被自动学习，下次识别更准。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 416, height: 180))
        textView.string = original
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let edited = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.isEmpty, edited != original else { return }

        guard historyStore.updateEntry(matching: entry, newASR: nil, newOutput: edited) else {
            presentHistoryActionResult(success: false, message: "保存失败，这条记录可能已被删除。")
            return
        }
        allHistoryEntries[index] = AIPolisher.PolishLog(
            time: entry.time, app: entry.app, asr: entry.asr, output: edited,
            duration_ms: entry.duration_ms, input_tokens: entry.input_tokens,
            output_tokens: entry.output_tokens, id: entry.id, audioFile: entry.audioFile)
        historyEntries = allHistoryEntries
        refreshHistoryCardInPlace(index: index)

        // 静默学习（受"自动学习"总开关控制），学到的词条出现在词库页"自动学习"分类里
        if config.bool(forKey: "term_corrections_auto_learn_enabled", defaultValue: true) {
            _ = HotWordsAutoLearner.shared.learnFromManualCorrection(original: original, corrected: edited)
        }
    }

    @objc private func repolishHistoryEntry(_ sender: NSMenuItem) {
        guard processingIndex == nil else { return }
        let index = sender.tag
        guard allHistoryEntries.indices.contains(index) else { return }
        let entry = allHistoryEntries[index]
        let polisher = AIPolisher()
        polisher.polishLogAppNameProvider = { entry.app }
        guard polisher.isPolishEnabled() else {
            presentHistoryActionResult(success: false, message: "「语音优化」当前为「不优化」，无法重新润色。先去「模型」里选一个润色模型。")
            return
        }
        beginInlineProcessing(index: index, label: "正在重新润色…")
        polisher.polishCloudASROutput(text: entry.asr) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let polished):
                    let newOutput = polished.isEmpty ? entry.asr : polished
                    _ = self.historyStore.updateEntry(matching: entry, newASR: nil, newOutput: newOutput)
                    self.endInlineProcessingRepolish(index: index)
                case .failure(let err):
                    self.endInlineProcessingRepolish(index: index)  // 恢复按钮（文本不变）
                    self.presentHistoryActionResult(success: false, message: "重新润色失败：\(err.localizedDescription)")
                }
            }
        }
    }

    /// 就地把某条历史卡换成按最新数据渲染的新卡——不整页重建，保住滚动位置与已加载批次。
    /// 用于重新转写完成后刷新那一条（会同时改原文+输出、结构可能变，故整张卡重建而非只改 label）。
    /// 找不到该卡（极少见）则兜底退回整页刷新。
    private func refreshHistoryCardInPlace(index: Int) {
        guard let stack = historyContentStack,
              let old = cardViews[index],
              let pos = stack.arrangedSubviews.firstIndex(of: old),
              allHistoryEntries.indices.contains(index) else {
            invalidate(.history)
            return
        }
        let fresh = makeHistoryCard(entry: allHistoryEntries[index], index: index)
        stack.removeArrangedSubview(old)
        old.removeFromSuperview()
        stack.insertArrangedSubview(fresh, at: pos)
        fresh.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        cardViews[index] = fresh
    }

    @objc private func retranscribeHistoryEntry(_ sender: NSMenuItem) {
        guard processingIndex == nil else { return }
        let index = sender.tag
        guard allHistoryEntries.indices.contains(index) else { return }
        let entry = allHistoryEntries[index]
        guard let audioFile = entry.audioFile else {
            presentHistoryActionResult(success: false, message: "音频已不存在，无法重新转写。")
            return
        }
        // 先让转圈出现、再干重活：解密 + 解码 M4A 有明显耗时，放在主线程会把界面卡住，
        // 连转圈都出不来，用户以为"点了没反应"。
        beginInlineProcessing(index: index, label: "正在重新转写…")
        let log: (String) -> Void = { [weak self] m in
            self?.settingsDelegate?.debugLog(m)
        }
        let tStart = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let samples = self.audioStore.loadSamples(fileName: audioFile), !samples.isEmpty else {
                DispatchQueue.main.async {
                    self.endInlineProcessingRepolish(index: index)
                    self.presentHistoryActionResult(success: false, message: "音频已不存在，无法重新转写。")
                }
                return
            }
            let decodeMs = Int(Date().timeIntervalSince(tStart) * 1000)
            let audioSec = Double(samples.count) / 16000.0
            // 重试没有「边录边发」的抢跑，整段都要重识别，耗时随录音长度线性增长——
            // 这些数字就是用来判断慢在解码还是识别的。
            log(String(format: "History retry: 解码完成 %dms, 音频 %.1fs, 开始重新转写", decodeMs, audioSec))
            self.performRetranscribe(index: index, entry: entry, samples: samples, tStart: tStart, log: log)
        }
    }

    /// 重新转写的实际执行（已在后台线程；转圈此时已经在转）。
    /// 重新转写会改变原文+输出（结构可能变），完成后就地换卡；失败则恢复。
    /// 与主流水线一致走自动分段入口，长录音重试同样享受并行加速。
    private func performRetranscribe(index: Int, entry: AIPolisher.PolishLog, samples: [Float],
                                     tStart: Date, log: @escaping (String) -> Void) {
        let transcriber = CloudASRTranscriber()
        transcriber.debugLog = log        // 让分段/版本/预算等信息跟主流水线一样进日志
        let tASR = Date()
        transcriber.transcribeAuto(samples: samples, sampleRate: 16000, version: transcriber.currentVersion()) { [weak self] result in
            guard let self = self else { return }
            log(String(format: "History retry: 识别耗时 %.1fs", Date().timeIntervalSince(tASR)))
            switch result {
            case .failure(let err):
                log("History retry: 识别失败 \(err.localizedDescription)")
                DispatchQueue.main.async {
                    self.endInlineProcessingRepolish(index: index)
                    self.presentHistoryActionResult(success: false, message: "重新转写失败：\(err.localizedDescription)")
                }
            case .success(let rawText):
                let polisher = AIPolisher()
                polisher.debugLog = log
                polisher.polishLogAppNameProvider = { entry.app }
                let shouldPolish = polisher.isPolishEnabled() && polisher.meaningfulCharacterCount(in: rawText) > 10
                let tPolish = Date()
                let finish: (String) -> Void = { output in
                    // 与主流水线一致：最后过一遍术语纠正（替换词）
                    let corrected = polisher.applyConfiguredTermCorrections(to: output)
                    log(String(format: "History retry: 润色耗时 %.1fs, 全程 %.1fs, 输出 %d 字",
                               shouldPolish ? Date().timeIntervalSince(tPolish) : 0,
                               Date().timeIntervalSince(tStart), corrected.count))
                    DispatchQueue.main.async {
                        _ = self.historyStore.updateEntry(matching: entry, newASR: rawText, newOutput: corrected)
                        // 同步内存里这条，再就地换这张卡——不整页重建，保住用户的滚动位置与已加载批次。
                        if self.allHistoryEntries.indices.contains(index) {
                            let e = self.allHistoryEntries[index]
                            self.allHistoryEntries[index] = AIPolisher.PolishLog(
                                time: e.time, app: e.app, asr: rawText, output: corrected,
                                duration_ms: e.duration_ms, input_tokens: e.input_tokens,
                                output_tokens: e.output_tokens, id: e.id, audioFile: e.audioFile)
                        }
                        self.processingIndex = nil
                        self.refreshHistoryCardInPlace(index: index)
                    }
                }
                if shouldPolish {
                    polisher.polishCloudASROutput(text: rawText) { presult in
                        if case .success(let p) = presult, !p.isEmpty { finish(p) } else { finish(rawText) }
                    }
                } else {
                    finish(rawText)
                }
            }
        }
    }

    @objc private func deleteHistoryEntry(_ sender: NSMenuItem) {
        guard allHistoryEntries.indices.contains(sender.tag) else { return }
        let entry = allHistoryEntries[sender.tag]
        let alert = NSAlert()
        alert.messageText = "删除这条历史记录？"
        alert.informativeText = "会同时删除它的文字和音频，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = historyStore.deleteEntry(matching: entry)
        rebuildSidebar()
        invalidate(.history)
    }

    private func presentHistoryActionResult(success: Bool, message: String) {
        let alert = NSAlert()
        alert.messageText = success ? "完成" : "未能完成"
        alert.informativeText = message
        alert.alertStyle = success ? .informational : .warning
        alert.addButton(withTitle: "好")
        if let window = window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            _ = alert.runModal()
        }
    }

    /// 点「导出…」：在按钮下方弹出时间范围菜单（tag 即天数，0=全部）。
    @objc private func exportHistory(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, tag) in [("最近 7 天", 7), ("最近一个月", 30), ("全部", 0)] {
            let item = NSMenuItem(title: title, action: #selector(exportHistoryRange(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func exportHistoryRange(_ sender: NSMenuItem) {
        let retention: AIPolisher.HistoryRetention
        let rangeTag: String
        switch sender.tag {
        case 7: retention = .oneWeek; rangeTag = "最近7天"
        case 30: retention = .oneMonth; rangeTag = "最近一个月"
        default: retention = .forever; rangeTag = "全部"
        }
        guard let markdown = historyStore.exportAllAsMarkdown(retention: retention) else {
            presentHistoryActionResult(success: false, message: "所选时间范围内没有记录可导出。")
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Typefree 转写记录 \(rangeTag) \(df.string(from: Date())).md"
        panel.message = "导出的文件是明文（未加密），请妥善保管。"
        panel.begin { [weak self] resp in
            guard resp == .OK, let dst = panel.url else { return }
            do {
                try markdown.write(to: dst, atomically: true, encoding: .utf8)
            } catch {
                self?.presentHistoryActionResult(success: false, message: "写入文件失败：\(error.localizedDescription)")
            }
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "清空本地历史记录？"
        alert.informativeText = "这只会清空本机的历史文件，不会影响个人词库和 API 配置。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        historyStore.clear()
        rebuildSidebar()
        invalidate(.history)
    }

    /// 保存时长：一套逻辑同时管文字和音频——音频始终跟着文字存、按同一时长一起过期删除。
    private func makeHistoryRetentionCard() -> NSView {
        let card = makeCard()

        let title = label("语音输入内容保存时长", size: 14, weight: .medium, color: theme.text)
        let sub = label("文字和音频一起保存。默认保存全部数据；改成较短时长后，过期的本地历史会自动删除。",
                        size: 12, weight: .regular, color: theme.text3)
        sub.maximumNumberOfLines = 0

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(sub)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let retentionBtn = VPButton(title: AIPolisher.currentHistoryRetention().title + "  ▾",
                                    style: .secondary, size: .regular,
                                    theme: theme, target: self, action: #selector(showRetentionMenu(_:)))
        retentionBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 18
        row.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(retentionBtn)

        mount(row, in: card)
        return card
    }

    @objc private func showRetentionMenu(_ sender: VPButton) {
        let menu = NSMenu()
        let current = AIPolisher.currentHistoryRetention()
        for retention in AIPolisher.HistoryRetention.allCases {
            let item = NSMenuItem(title: retention.title, action: #selector(retentionMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = retention.rawValue
            item.state = (retention == current) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func retentionMenuPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let retention = AIPolisher.HistoryRetention(rawValue: raw) else { return }

        config.save(value: retention.rawValue, forKey: AIPolisher.HistoryRetention.configKey)
        historyStore.pruneExpiredEntries()
        rebuildSidebar()
        invalidate(.history)   // 重建历史页 → 按钮按新 title 重新渲染
    }

    // MARK: - Page: Vocabulary

    private func buildVocab(into stack: NSStackView) {
        loadVocabularyEntries()

        let header = pageHeader(
            eyebrow: "TYPEFREE / 个人词库",
            title: "个人词库",
            sub: "添加你常说的人名、产品名、专有名词，语音识别会优先认出它们。你改过的错词也会自动学进来。"
        )
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(20, after: header)

        // 快速添加：输入框回车即加，不弹窗
        let quickAdd = makeVocabQuickAddRow()
        stack.addArrangedSubview(quickAdd)
        stack.setCustomSpacing(20, after: quickAdd)

        // 词条网格（含筛选）
        if vocabularyEntries.isEmpty {
            let empty = makeEmptyState("还没有词。在上面输入一个常说的人名、产品名试试。")
            stack.addArrangedSubview(empty)
            stack.setCustomSpacing(20, after: empty)
        } else {
            let seg = VPSegmentedControl(
                labels: ["所有", "自动学习", "手动添加"],
                trackBg: theme.cardAlt,
                trackBorder: theme.sep,
                selBg: theme.segSelBg,
                selBorder: theme.sep,
                selText: theme.text,
                normalText: theme.text2,
                target: self,
                action: #selector(vocabFilterChanged(_:)))
            seg.selectedSegment = vocabFilter
            seg.widthAnchor.constraint(equalToConstant: 280).isActive = true
            stack.addArrangedSubview(seg)
            stack.setCustomSpacing(14, after: seg)

            let visible: [(index: Int, entry: VocabularyEntry)] = vocabularyEntries.enumerated()
                .filter { item in
                    switch vocabFilter {
                    case 1: return item.element.isAutoLearned
                    case 2: return !item.element.isAutoLearned
                    default: return true
                    }
                }
                .map { (index: $0.offset, entry: $0.element) }

            if visible.isEmpty {
                let empty = label(vocabFilter == 1 ? "还没有自动学到的词。" : "还没有手动添加的词。",
                                  size: 13, weight: .regular, color: theme.text3)
                stack.addArrangedSubview(empty)
                stack.setCustomSpacing(20, after: empty)
            } else {
                let grid = makeVocabGrid(visible)
                stack.addArrangedSubview(grid)
                stack.setCustomSpacing(20, after: grid)
            }
        }

        // 词库相关开关
        let autoLearn = makeAutoLearnCard()
        stack.addArrangedSubview(autoLearn)
        stack.setCustomSpacing(8, after: autoLearn)
        stack.addArrangedSubview(makeBuiltinHotWordsCard())
    }

    @objc private func vocabFilterChanged(_ sender: VPSegmentedControl) {
        vocabFilter = sender.selectedSegment
        invalidate(.vocabulary)
    }

    // MARK: 快速添加

    private func makeVocabQuickAddRow() -> NSView {
        let field = NSTextField()
        field.placeholderString = "输入常说的词，回车添加"
        field.font = .systemFont(ofSize: 14)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(vocabQuickAddSubmitted)
        if let cell = field.cell as? NSTextFieldCell {
            cell.sendsActionOnEndEditing = false   // 只在回车时触发，失焦不误加
        }
        vocabQuickAddField = field

        // 系统默认 bezel 太淡，包进圆角容器自己画明显的边框（与反馈输入框同做法、边框更深）
        let fieldWrap = NSView()
        fieldWrap.wantsLayer = true
        fieldWrap.layer?.cornerRadius = 8
        fieldWrap.layer?.borderWidth = 1.5
        fieldWrap.layer?.setAppearanceBorder(theme.text3)
        fieldWrap.layer?.setAppearanceBackground(theme.card)
        fieldWrap.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        fieldWrap.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: fieldWrap.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: fieldWrap.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: fieldWrap.centerYAnchor),
            fieldWrap.heightAnchor.constraint(equalToConstant: 32),
        ])

        let addBtn = VPButton(title: "添加词汇", style: .primary, size: .regular,
                              theme: theme, target: self, action: #selector(vocabQuickAddSubmitted))
        addBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.addArrangedSubview(fieldWrap)
        row.addArrangedSubview(addBtn)
        fieldWrap.widthAnchor.constraint(equalToConstant: 340).isActive = true
        addBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true

        // 包一层让整行靠左、不被拉伸
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    @objc private func vocabQuickAddSubmitted() {
        guard let field = vocabQuickAddField else { return }
        let word = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        field.stringValue = ""
        // 已有同名词条就不重复加（输入框已清空，效果上等于"已收录"）
        if vocabularyEntries.contains(where: { $0.target.caseInsensitiveCompare(word) == .orderedSame }) {
            return
        }
        vocabularyEntries.insert(
            VocabularyEntry(target: word, variants: [], category: "其他", source: "manual"),
            at: 0
        )
        saveVocabularyEntries()
        rebuildSidebar()
        invalidate(.vocabulary)
        // 页面重建后把焦点放回输入框，方便连续添加
        DispatchQueue.main.async { [weak self] in
            guard let self, let newField = self.vocabQuickAddField else { return }
            self.window?.makeFirstResponder(newField)
        }
    }

    // MARK: 词条网格

    /// 3 列网格，参考竞品排版：词卡 = 来源图标 + 词，悬停浮现「错法/删除」操作
    private func makeVocabGrid(_ items: [(index: Int, entry: VocabularyEntry)]) -> NSView {
        let columns = 3
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        var rowStart = 0
        while rowStart < items.count {
            let rowItems = Array(items[rowStart..<min(rowStart + columns, items.count)])
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = 10
            for item in rowItems {
                row.addArrangedSubview(makeVocabChip(entry: item.entry, originalIndex: item.index))
            }
            // 末行不足 3 个时用占位补齐，保持卡片等宽
            for _ in rowItems.count..<columns {
                let filler = NSView()
                filler.translatesAutoresizingMaskIntoConstraints = false
                row.addArrangedSubview(filler)
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            rowStart += columns
        }
        return grid
    }

    private func makeVocabChip(entry: VocabularyEntry, originalIndex: Int) -> NSView {
        let chip = VocabChipView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 10
        chip.layer?.borderWidth = 1
        chip.layer?.setAppearanceBorder(theme.sep)
        chip.layer?.setAppearanceBackground(theme.card)
        chip.normalBg = theme.card
        chip.hoverBg = theme.cardAlt
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: entry.isAutoLearned ? "sparkles" : "pencil",
                             accessibilityDescription: entry.isAutoLearned ? "自动学习" : "手动添加")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        icon.contentTintColor = theme.text3
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let word = label(entry.target, size: 13, weight: .medium, color: theme.text)
        word.lineBreakMode = .byTruncatingTail
        word.maximumNumberOfLines = 1
        word.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 已记录错法数的弱提示（悬停时让位给操作按钮）
        let hint: NSTextField? = entry.variants.isEmpty
            ? nil
            : label("\(entry.variants.count) 个错法", size: 10.5, weight: .regular, color: theme.text3)

        let variantsBtn = makeChipIconButton(symbol: "character.cursor.ibeam",
                                             tooltip: "管理常见错法",
                                             action: #selector(manageVariantsTapped(_:)),
                                             tag: originalIndex)
        let deleteBtn = makeChipIconButton(symbol: "trash",
                                           tooltip: "删除",
                                           action: #selector(deleteVocabularyEntry(_:)),
                                           tag: originalIndex)
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.addArrangedSubview(variantsBtn)
        actions.addArrangedSubview(deleteBtn)
        actions.isHidden = true

        chip.onHoverChange = { [weak actions, weak hint] hovering in
            actions?.isHidden = !hovering
            hint?.isHidden = hovering
        }

        let inner = NSStackView()
        inner.orientation = .horizontal
        inner.alignment = .centerY
        inner.spacing = 8
        inner.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        inner.addArrangedSubview(icon)
        inner.addArrangedSubview(word)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inner.addArrangedSubview(spacer)
        if let hint { inner.addArrangedSubview(hint) }
        inner.addArrangedSubview(actions)
        inner.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            inner.topAnchor.constraint(equalTo: chip.topAnchor),
            inner.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
        ])
        return chip
    }

    private func makeChipIconButton(symbol: String, tooltip: String, action: Selector, tag: Int) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let btn = NSButton(image: image, target: self, action: action)
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.contentTintColor = theme.text3
        btn.toolTip = tooltip
        btn.tag = tag
        return btn
    }

    @objc private func deleteVariantTapped(_ sender: NSButton) {
        let entryIndex = sender.tag / 1000
        let variantIndex = sender.tag % 1000
        guard vocabularyEntries.indices.contains(entryIndex),
              vocabularyEntries[entryIndex].variants.indices.contains(variantIndex) else { return }
        vocabularyEntries[entryIndex].variants.remove(at: variantIndex)
        saveVocabularyEntries()
        variantPopover?.close()
        invalidate(.vocabulary)
    }

    @objc private func deleteVocabularyEntry(_ sender: NSButton) {
        guard vocabularyEntries.indices.contains(sender.tag) else { return }
        let entry = vocabularyEntries[sender.tag]
        let alert = NSAlert()
        alert.messageText = "删除个人词语"
        alert.informativeText = "确定删除「\(entry.target)」吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        vocabularyEntries.remove(at: sender.tag)
        saveVocabularyEntries()
        rebuildSidebar()
        invalidate(.vocabulary)
    }

    // MARK: 错法管理（小气泡：看已有错法、删、加，不弹系统对话框）

    @objc private func manageVariantsTapped(_ sender: NSButton) {
        let index = sender.tag
        guard vocabularyEntries.indices.contains(index) else { return }
        variantPopover?.close()

        let entry = vocabularyEntries[index]

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = label("「\(entry.target)」常被错识别成", size: 12, weight: .medium, color: theme.text2)
        content.addArrangedSubview(title)

        if !entry.variants.isEmpty {
            let chips = NSStackView()
            chips.orientation = .horizontal
            chips.alignment = .centerY
            chips.spacing = 6
            for (vi, v) in entry.variants.enumerated() {
                chips.addArrangedSubview(makePopoverVariantChip(text: v, entryIndex: index, variantIndex: vi))
            }
            content.addArrangedSubview(chips)
        }

        let field = NSTextField()
        field.placeholderString = "输入新错法，回车保存"
        field.font = .systemFont(ofSize: 12)
        field.target = self
        field.action = #selector(variantPopoverSubmitted)
        if let cell = field.cell as? NSTextFieldCell {
            cell.sendsActionOnEndEditing = false
        }
        content.addArrangedSubview(field)
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let wrapper = AppearanceObservingView()
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            content.topAnchor.constraint(equalTo: wrapper.topAnchor),
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])

        let vc = NSViewController()
        vc.view = wrapper
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc

        variantPopover = popover
        variantPopoverField = field
        variantPopoverEntryIndex = index
        // 钉在整张词条卡片上，不钉在图标上：图标是"悬停才显示"的，鼠标移向气泡时
        // 会离开词条、图标被藏起来——NSPopover 的锚点视图一不可见，气泡就自动关闭，
        // 造成"点开就消失、没法使用"（owner 2026-07-03 反馈）。卡片永远可见，气泡就稳了。
        var anchor: NSView = sender
        var probe: NSView? = sender.superview
        while let view = probe {
            if view is VocabChipView { anchor = view; break }
            probe = view.superview
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        field.becomeFirstResponder()
    }

    /// 气泡里的错法 chip：词 + ✕ 删除
    private func makePopoverVariantChip(text: String, entryIndex: Int, variantIndex: Int) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.layer?.setAppearanceBackground(theme.cardAlt)
        v.translatesAutoresizingMaskIntoConstraints = false

        let l = label(text, size: 11, weight: .regular, color: theme.text2)
        l.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "✕", target: self, action: #selector(deleteVariantTapped(_:)))
        close.isBordered = false
        close.font = .systemFont(ofSize: 9, weight: .medium)
        close.contentTintColor = theme.text3
        close.tag = entryIndex * 1000 + variantIndex   // 词条数远小于 1000，安全
        close.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(l)
        v.addSubview(close)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            l.topAnchor.constraint(equalTo: v.topAnchor, constant: 3),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -3),
            close.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 2),
            close.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            close.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    @objc private func variantPopoverSubmitted() {
        let index = variantPopoverEntryIndex
        guard let field = variantPopoverField,
              vocabularyEntries.indices.contains(index) else {
            variantPopover?.close()
            return
        }
        let variant = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        variantPopover?.close()
        guard !variant.isEmpty,
              variant.caseInsensitiveCompare(vocabularyEntries[index].target) != .orderedSame,
              !vocabularyEntries[index].variants.contains(where: { $0.caseInsensitiveCompare(variant) == .orderedSame }) else {
            return
        }
        vocabularyEntries[index].variants.append(variant)
        saveVocabularyEntries()
        invalidate(.vocabulary)
    }

    // MARK: 词库开关

    private func makeBuiltinHotWordsCard() -> NSView {
        let card = makeCard()

        let title = label("内置科技词热词", size: 14, weight: .medium, color: theme.text)
        let desc = label("Claude、Xcode、GitHub 等常用科技词。不常聊技术可以关掉。", size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        let toggle = VPToggle(theme: theme, target: self, action: #selector(builtinHotWordsChanged(_:)))
        toggle.setOn(config.bool(forKey: "bigasr_include_builtin_hot_words", defaultValue: true), animated: false)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(toggle)

        mount(row, in: card)
        return card
    }

    @objc private func builtinHotWordsChanged(_ sender: VPToggle) {
        config.save(bool: sender.isOn, forKey: "bigasr_include_builtin_hot_words")
    }

    // MARK: 词库存取

    private func loadVocabularyEntries() {
        guard let items = config.loadConfig()["term_corrections"] as? [[String: Any]] else {
            vocabularyEntries = []
            return
        }
        vocabularyEntries = items.compactMap { item in
            guard let target = (item["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty else { return nil }
            let variants = (item["variants"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != target }
            return VocabularyEntry(
                target: target,
                variants: variants,
                category: item["category"] as? String ?? "其他",
                source: item["source"] as? String ?? ""
            )
        }
    }

    private func saveVocabularyEntries() {
        let items: [[String: Any]] = vocabularyEntries.map {
            ["target": $0.target, "variants": $0.variants, "category": $0.category, "source": $0.source]
        }
        config.save(values: ["term_corrections": items])
    }

    // MARK: - Page: About

    private func buildAbout(into stack: NSStackView) {
        stack.addArrangedSubview(pageHeader(eyebrow: "TYPEFREE / 关于", title: "关于",
                                             sub: "语音转文字，并用 AI 帮你整理成可直接使用的文本。"))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // Logo card
        let card = makeCard()

        let logoBox = makeWaveformMark(box: 64, corner: 16, boxColor: theme.accent, waveColor: theme.onAccent)

        let name = label("Typefree", size: 22, weight: .semibold, color: theme.text)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "本地开发版"
        let sub = label("\(version) · macOS 状态栏应用", size: 13, weight: .regular, color: theme.text3)

        let logoStack = NSStackView()
        logoStack.orientation = .vertical
        logoStack.alignment = .centerX
        logoStack.spacing = 12
        logoStack.edgeInsets = NSEdgeInsets(top: 28, left: 16, bottom: 28, right: 16)
        logoStack.addArrangedSubview(logoBox)
        logoStack.addArrangedSubview(name)
        logoStack.addArrangedSubview(sub)
        logoStack.setCustomSpacing(4, after: name)

        if LicenseManager.shared.isActivated {
            let license = LicenseManager.shared
            var status = "✓ 已激活"
            if license.isMember {
                status = license.isMemberExpired() ? "会员已到期" : "✓ 会员 · 有效期至 \(license.memberExpiresDay ?? "—")"
            }
            let actLbl = label(license.isGenesis ? "\(status) · 创世用户" : status, size: 12, weight: .regular, color: theme.text3)
            logoStack.addArrangedSubview(actLbl)
            logoStack.setCustomSpacing(12, after: sub)
        }

        let hasPendingUpdate: Bool
        if let updateInfo = settingsDelegate?.pendingUpdateInfo(), updateInfo.errorMessage == nil {
            hasPendingUpdate = true
        } else {
            hasPendingUpdate = false
        }
        let updateButton = VPButton(title: hasPendingUpdate ? "查看新版本" : "检查更新…", style: .secondary, size: .regular,
                                    theme: theme, target: self, action: #selector(checkForUpdatesTapped(_:)))
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        updateButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        logoStack.addArrangedSubview(updateButton)
        logoStack.setCustomSpacing(14, after: LicenseManager.shared.isActivated ? logoStack.arrangedSubviews[3] : sub)

        mount(logoStack, in: card)
        stack.addArrangedSubview(card)
    }

    @objc private func checkForUpdatesTapped(_ sender: NSButton) {
        if let updateInfo = settingsDelegate?.pendingUpdateInfo(), updateInfo.errorMessage == nil {
            settingsDelegate?.showUpdateDetails(sender)
        } else {
            settingsDelegate?.checkForUpdates(sender)
        }
    }

    // MARK: - Reusable helpers

    private func pageHeader(eyebrow: String, title: String, sub: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let eyebrowLbl = label(eyebrow, size: 11, weight: .medium, color: theme.text3)
        let titleLbl = label(title, size: 28, weight: .semibold, color: theme.text)
        let subLbl = label(sub, size: 13, weight: .regular, color: theme.text2)
        subLbl.maximumNumberOfLines = 0
        stack.addArrangedSubview(eyebrowLbl)
        stack.addArrangedSubview(titleLbl)
        stack.addArrangedSubview(subLbl)
        stack.setCustomSpacing(2, after: eyebrowLbl)
        stack.setCustomSpacing(6, after: titleLbl)
        return stack
    }

    private enum HeaderButtonStyle { case accent, danger }

    private func makePageHeaderRow(eyebrow: String, title: String, sub: String,
                                    buttonTitle: String,
                                    buttonStyle: HeaderButtonStyle,
                                    buttonAction: Selector,
                                    secondaryTitle: String? = nil,
                                    secondaryAction: Selector? = nil) -> NSView {
        let container = NSView()
        let header = pageHeader(eyebrow: eyebrow, title: title, sub: sub)
        let btn = VPButton(title: buttonTitle,
                           style: (buttonStyle == .accent ? .primary : .danger),
                           theme: theme, target: self, action: buttonAction)
        btn.translatesAutoresizingMaskIntoConstraints = false
        [header, btn].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            btn.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            btn.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])

        // 可选「次按钮」（描边样式），放在主按钮左侧。
        if let secondaryTitle = secondaryTitle, let secondaryAction = secondaryAction {
            let sBtn = VPButton(title: secondaryTitle, style: .secondary,
                                theme: theme, target: self, action: secondaryAction)
            sBtn.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(sBtn)
            NSLayoutConstraint.activate([
                sBtn.trailingAnchor.constraint(equalTo: btn.leadingAnchor, constant: -8),
                sBtn.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
                header.trailingAnchor.constraint(lessThanOrEqualTo: sBtn.leadingAnchor, constant: -16),
            ])
        } else {
            header.trailingAnchor.constraint(lessThanOrEqualTo: btn.leadingAnchor, constant: -16).isActive = true
        }
        return container
    }

    private func sectionTitle(_ text: String) -> NSView {
        let lbl = label(text, size: 12, weight: .semibold, color: theme.text2)
        return lbl
    }

    private func makeCard() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        v.layer?.borderWidth = 1
        v.layer?.setAppearanceBorder(theme.sep)
        v.layer?.setAppearanceBackground(theme.card)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    private func mount(_ body: NSView, in card: NSView) {
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            body.topAnchor.constraint(equalTo: card.topAnchor),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    private func makeEmptyState(_ text: String) -> NSView {
        let card = makeCard()
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        let l = label(text, size: 13, weight: .regular, color: theme.text3)
        l.alignment = .center
        l.maximumNumberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24),
            l.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            l.topAnchor.constraint(equalTo: body.topAnchor, constant: 36),
            l.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -36),
        ])
        mount(body, in: card)
        return card
    }

    private func makePill(text: String) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.layer?.setAppearanceBackground(theme.cardAlt)
        let l = label(text, size: 11, weight: .regular, color: theme.text2)
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            l.topAnchor.constraint(equalTo: v.topAnchor, constant: 2),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -2),
        ])
        return v
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.isSelectable = false
        l.alignment = .left
        l.lineBreakMode = .byWordWrapping
        return l
    }

    /// 多行自适应标签（用于历史正文/原文这类可能很长的文本，按真实宽度算高度，不会被截断）。
    private func makeWrappingLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) -> WrappingLabel {
        let l = WrappingLabel(frame: .zero)
        l.isEditable = false
        l.isSelectable = false
        l.isBordered = false
        l.drawsBackground = false
        l.stringValue = text
        l.font = mono ? monoFont(size: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .left
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        l.cell?.wraps = true
        l.cell?.isScrollable = false
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func monoFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private func circle(color: NSColor, size: CGFloat) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.setAppearanceBackground(color)
        v.layer?.cornerRadius = size / 2
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: size),
            v.heightAnchor.constraint(equalToConstant: size),
        ])
        return v
    }

    private func makeTextField(_ value: String?, mono: Bool = false) -> NSTextField {
        let f = NSTextField()
        f.stringValue = value ?? ""
        if mono {
            f.font = monoFont(size: 12, weight: .regular)
        }
        return f
    }

    private func makeSecureField(_ value: String?) -> NSSecureTextField {
        let f = NSSecureTextField()
        f.stringValue = value ?? ""
        return f
    }

    private func isPolishConfigured() -> Bool {
        let provider = config.string(forKey: "polish_provider") ?? "qwen"
        switch provider {
        case "qwen":
            return !(config.string(forKey: "dashscope_api_key", envKey: "DASHSCOPE_API_KEY") ?? "").isEmpty
        case "zhipu":
            return !(config.string(forKey: "zhipu_api_key", envKey: "ZHIPU_API_KEY") ?? "").isEmpty
        case "none":
            return true   // 用户主动选了「不优化」，不是没配置
        default:
            return !(config.string(forKey: "ark_api_key", envKey: "ARK_API_KEY") ?? "").isEmpty
        }
    }

    private func quickHistoryLineCount() -> Int {
        historyStore.pruneExpiredEntries()
        guard let data = try? Data(contentsOf: historyStore.fileURL) else { return 0 }
        var count = 0
        for byte in data where byte == 0x0A { count += 1 }
        return count
    }

    /// 把存储的 "2026-05-12 00:55:49" 转成更友好的"今天 00:55" / "昨天 18:32" / "5月10日 14:00"
    private func formatHistoryTime(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: raw) else { return raw }

        let timeFormat = DateFormatter()
        timeFormat.dateFormat = "HH:mm"
        let hm = timeFormat.string(from: date)

        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天 \(hm)" }
        if cal.isDateInYesterday(date) { return "昨天 \(hm)" }

        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "zh_CN")
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            dayFormat.dateFormat = "M月d日 HH:mm"
        } else {
            dayFormat.dateFormat = "yyyy年M月d日 HH:mm"
        }
        return dayFormat.string(from: date)
    }

    private func formatNumber(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func showAlert(title: String, message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "好")
        a.runModal()
    }
}

// MARK: - Dashed divider

private final class DashedDivider: NSView {
    var color: NSColor = .separatorColor

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.move(to: CGPoint(x: 0, y: bounds.midY))
        ctx.addLine(to: CGPoint(x: bounds.width, y: bounds.midY))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

// MARK: - Microphone picker sheet

private final class MicrophonePickerSheet: NSObject, NSWindowDelegate {
    private let theme: VPTheme
    private var sheet: NSWindow?
    private var listStack: NSStackView?
    private var meterView: VUMeterView?
    private var meterEngine: AVAudioEngine?
    private var meterAudioUnit: AudioUnit?
    private var meterFormat: AVAudioFormat?
    private var meterDeviceID: AudioDeviceID?
    private var onClose: (() -> Void)?

    init(theme: VPTheme) {
        self.theme = theme
        super.init()
    }

    func present(over host: NSWindow, onClose: @escaping () -> Void) {
        self.onClose = onClose

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "麦克风"
        sheet.titlebarAppearsTransparent = true
        sheet.isReleasedWhenClosed = false
        sheet.delegate = self
        self.sheet = sheet

        let cv = KeyAwareView()
        cv.onEscape = { [weak self] in self?.dismiss() }
        cv.wantsLayer = true
        cv.layer?.setAppearanceBackground(theme.bg)
        sheet.contentView = cv

        let title = NSTextField(labelWithString: "麦克风")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = theme.text
        let sub = NSTextField(wrappingLabelWithString: "选择能捕捉到你声音的麦克风。如果指示条没有跳动，请试试别的。")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = theme.text2
        sub.maximumNumberOfLines = 0

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = documentView

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(listStack)
        self.listStack = listStack

        let doneBtn = VPButton(title: "完成", style: .primary, size: .regular,
                               theme: theme, target: self, action: #selector(doneTapped))
        doneBtn.keyEquivalent = "\r"
        doneBtn.translatesAutoresizingMaskIntoConstraints = false

        title.translatesAutoresizingMaskIntoConstraints = false
        sub.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(title)
        cv.addSubview(sub)
        cv.addSubview(scroll)
        cv.addSubview(doneBtn)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -28),
            title.topAnchor.constraint(equalTo: cv.topAnchor, constant: 18),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 18),
            scroll.bottomAnchor.constraint(equalTo: doneBtn.topAnchor, constant: -16),
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            doneBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),
            doneBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -18),
        ])

        rebuildList()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onListOrSelChanged),
            name: .voicePolishMicrophoneListDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onListOrSelChanged),
            name: .voicePolishMicrophoneSelectionDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingWillStart),
            name: .voicePolishRecordingWillStart,
            object: nil
        )

        host.beginSheet(sheet) { [weak self] _ in
            self?.teardown()
        }

        // Defer meter start so sheet animates in smoothly first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startMeterForCurrentSelection()
        }
    }

    @objc private func onListOrSelChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildList()
            self?.startMeterForCurrentSelection()
        }
    }

    @objc private func recordingWillStart() {
        stopMeter()
    }

    private func rebuildList() {
        guard let listStack else { return }
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let mgr = MicrophoneManager.shared
        let followingName = mgr.systemDefaultDeviceName ?? "未知"
        listStack.addArrangedSubview(makeRow(
            uid: MicrophoneManager.systemDefaultUID,
            primary: "跟随系统默认（\(followingName)）",
            secondary: "随系统输入设置切换",
            isSelected: mgr.selectedUID == MicrophoneManager.systemDefaultUID,
            isRecommended: false
        ))

        for device in mgr.devices {
            listStack.addArrangedSubview(makeRow(
                uid: device.uid,
                primary: device.name,
                secondary: device.isBuiltIn ? "Mac 内置麦克风" : "外部麦克风",
                isSelected: mgr.selectedUID == device.uid,
                isRecommended: device.isBuiltIn
            ))
        }
        for v in listStack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -8).isActive = true
        }
    }

    private func makeRow(uid: String, primary: String, secondary: String, isSelected: Bool, isRecommended: Bool) -> NSView {
        let row = MicrophoneRowView(uid: uid)
        row.onClick = { [weak self] selectedUID in
            MicrophoneManager.shared.select(uid: selectedUID)
            self?.rebuildList()
            self?.startMeterForCurrentSelection()
        }
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.borderWidth = isSelected ? 2 : 1
        row.layer?.setAppearanceBorder((isSelected ? theme.accent : theme.sep))
        row.layer?.setAppearanceBackground((isSelected ? theme.accentSoft : theme.card))

        let p = NSTextField(labelWithString: primary)
        p.font = .systemFont(ofSize: 14, weight: .medium)
        p.textColor = theme.text
        p.lineBreakMode = .byTruncatingTail

        let s = NSTextField(labelWithString: secondary)
        s.font = .systemFont(ofSize: 11)
        s.textColor = theme.text3

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(p)
        textStack.addArrangedSubview(s)

        let recommended: NSView
        if isRecommended {
            let pill = NSTextField(labelWithString: "推荐")
            pill.font = .systemFont(ofSize: 10, weight: .semibold)
            pill.textColor = theme.accent
            pill.backgroundColor = theme.accentSoft
            pill.drawsBackground = true
            pill.isBezeled = false
            pill.isEditable = false
            pill.alignment = .center
            pill.wantsLayer = true
            pill.layer?.cornerRadius = 4
            pill.layer?.masksToBounds = true
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.widthAnchor.constraint(equalToConstant: 36).isActive = true
            pill.heightAnchor.constraint(equalToConstant: 18).isActive = true
            recommended = pill
        } else {
            recommended = NSView()
        }

        let meterContainer = NSView()
        meterContainer.translatesAutoresizingMaskIntoConstraints = false
        meterContainer.widthAnchor.constraint(equalToConstant: 70).isActive = true
        meterContainer.heightAnchor.constraint(equalToConstant: 18).isActive = true
        if isSelected {
            let meter = VUMeterView()
            meter.tint = theme.accent
            meter.translatesAutoresizingMaskIntoConstraints = false
            meterContainer.addSubview(meter)
            NSLayoutConstraint.activate([
                meter.leadingAnchor.constraint(equalTo: meterContainer.leadingAnchor),
                meter.trailingAnchor.constraint(equalTo: meterContainer.trailingAnchor),
                meter.topAnchor.constraint(equalTo: meterContainer.topAnchor),
                meter.bottomAnchor.constraint(equalTo: meterContainer.bottomAnchor),
            ])
            self.meterView = meter
        }

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(textStack)
        stack.addArrangedSubview(NSView())
        if isRecommended { stack.addArrangedSubview(recommended) }
        stack.addArrangedSubview(meterContainer)
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        row.identifier = NSUserInterfaceItemIdentifier(uid)
        return row
    }

    @objc private func rowTapped(_ gesture: NSClickGestureRecognizer) {
        guard let v = gesture.view, let uid = v.identifier?.rawValue else { return }
        MicrophoneManager.shared.select(uid: uid)
    }

    // MARK: VU meter

    private func startMeterForCurrentSelection() {
        stopMeter()
        let manager = MicrophoneManager.shared
        guard let deviceID = manager.resolvedDeviceID else { return }
        meterDeviceID = deviceID

        if manager.selectedUID != MicrophoneManager.systemDefaultUID {
            startAUHALMeter(deviceID: deviceID)
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let chan = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            var peak: Float = 0
            for i in 0..<count {
                let v = abs(chan[0][i])
                if v > peak { peak = v }
            }
            DispatchQueue.main.async { self.meterView?.update(level: peak) }
        }
        do {
            engine.prepare()
            try engine.start()
            meterEngine = engine
        } catch {
            NSLog("[MicrophonePicker] meter engine failed: %@", error.localizedDescription)
        }
    }

    private func startAUHALMeter(deviceID: AudioDeviceID) {
        var mutableDeviceID = deviceID
        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            NSLog("[MicrophonePicker] HALOutput component not found")
            return
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            NSLog("[MicrophonePicker] AudioComponentInstanceNew failed: %d", Int(status))
            return
        }

        func fail(_ operation: String, _ status: OSStatus) {
            NSLog("[MicrophonePicker] %@ failed: %d", operation, Int(status))
            AudioComponentInstanceDispose(unit)
            meterFormat = nil
        }

        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { fail("Enable AUHAL input", status); return }

        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { fail("Disable AUHAL output", status); return }

        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { fail("Set AUHAL input device", status); return }

        let sampleRate = nominalSampleRate(for: deviceID) ?? 48_000
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            fail("Create AUHAL meter format", -1)
            return
        }
        meterFormat = format
        var streamDescription = format.streamDescription.pointee
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &streamDescription,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else { fail("Set AUHAL stream format", status); return }

        var callback = AURenderCallbackStruct(
            inputProc: MicrophonePickerSheet.auhalMeterCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else { fail("Set AUHAL meter callback", status); return }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { fail("AudioUnitInitialize", status); return }

        meterAudioUnit = unit
        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            AudioUnitUninitialize(unit)
            fail("AudioOutputUnitStart", status)
            meterAudioUnit = nil
            return
        }
    }

    private static let auhalMeterCallback: AURenderCallback = { refCon, flags, timestamp, _, frameCount, _ in
        let picker = Unmanaged<MicrophonePickerSheet>.fromOpaque(refCon).takeUnretainedValue()
        return picker.renderAUHALMeter(flags: flags, timestamp: timestamp, frameCount: frameCount)
    }

    private func renderAUHALMeter(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard let unit = meterAudioUnit else { return noErr }

        let byteCount = Int(frameCount) * MemoryLayout<Float>.size
        let data = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Float>.alignment)
        defer { data.deallocate() }

        let audioBuffer = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(byteCount),
            mData: data
        )
        var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
        let status = AudioUnitRender(unit, flags, timestamp, 1, frameCount, &bufferList)
        guard status == noErr else { return status }

        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(frameCount)
        var rms: Float = 0
        var peak: Float = 0
        for i in 0..<count {
            let sample = samples[i]
            rms += sample * sample
            let v = Swift.abs(sample)
            if v > peak { peak = v }
        }
        rms = sqrt(rms / max(Float(count), 1))
        let level = min(max(peak * 3.0, rms * 12.0), 1.0)
        DispatchQueue.main.async { [weak self] in
            self?.meterView?.update(level: level)
        }
        return noErr
    }

    private func stopMeter() {
        if let e = meterEngine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        meterEngine = nil
        if let unit = meterAudioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        meterAudioUnit = nil
        meterFormat = nil
        meterDeviceID = nil
    }

    private func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard status == noErr, sampleRate > 0 else { return nil }
        return sampleRate
    }

    @objc private func doneTapped() {
        dismiss()
    }

    private func dismiss() {
        guard let sheet, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
    }

    private func teardown() {
        stopMeter()
        NotificationCenter.default.removeObserver(self)
        onClose?()
        onClose = nil
        sheet?.delegate = nil
        sheet = nil
    }

    func windowWillClose(_ notification: Notification) {
        teardown()
    }
}

private final class MicrophoneRowView: NSView {
    let uid: String
    var onClick: ((String) -> Void)?

    init(uid: String) {
        self.uid = uid
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(uid)
    }
}

private final class KeyAwareView: AppearanceObservingView {
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // ESC
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - VU meter (bar style)

private final class VUMeterView: NSView {
    private var level: CGFloat = 0  // smoothed, 0...1
    var tint: NSColor = .systemBlue
    private let segmentCount = 7

    override var isFlipped: Bool { false }

    func update(level peak: Float) {
        let target = CGFloat(min(max(peak * 1.4, 0), 1))
        // Smooth rise, faster fall
        if target > level {
            level = level * 0.4 + target * 0.6
        } else {
            level = level * 0.85 + target * 0.15
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let segGap: CGFloat = 3
        let segWidth = (bounds.width - segGap * CGFloat(segmentCount - 1)) / CGFloat(segmentCount)
        let segHeight = bounds.height
        let activeCount = Int(round(level * CGFloat(segmentCount)))
        let inactive = tint.withAlphaComponent(0.18)
        for i in 0..<segmentCount {
            let x = CGFloat(i) * (segWidth + segGap)
            let r = NSRect(x: x, y: 0, width: segWidth, height: segHeight)
            (i < activeCount ? tint : inactive).setFill()
            let path = NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5)
            path.fill()
        }
        _ = ctx  // silence unused warning
    }
}

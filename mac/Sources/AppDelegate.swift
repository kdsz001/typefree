import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 集中管理外部链接，换地址只改这里。
enum AppLinks {
    /// API key 图文教程页（官网教程，含火山 + 阿里完整图文步骤）。
    static let apiKeyGuideURL = "https://kdsz001.github.io/typefree/setup-guide.html"
    /// 购买页（官网定价板块：年付会员银行卡自动续费 / 微信一次性年卡，Paddle 结账，付款后邮件自动发授权码）。
    static let purchaseURL = "https://typefree.app/#pricing"
    /// 开源代码仓库（GPL-3.0，Mac 版源码在 mac/ 目录）。
    static let sourceCodeURL = "https://github.com/kdsz001/typefree"
    /// Sparkle 更新源；同时作为 App 内「更新历史」的数据源（含各版本日期与更新说明）。
    static let appcastURL = "https://typefree.app/appcast.xml"
}

extension Bundle {
    /// 展示用版本号（CFBundleShortVersionString），取不到时为空串。
    var appVersionString: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}

struct TypefreeUpdateInfo: Equatable {
    let title: String
    let displayVersion: String
    let buildVersion: String
    let releaseNotes: String
    let infoURL: URL?
    var isReadyToInstall: Bool
    var isDownloading: Bool
    var downloadProgress: Double = 0   // 0..1，下载进度（实时刷新对话框副标题用）
    var errorMessage: String?

    /// 除下载进度外其余字段是否一致。进度只影响弹窗副标题，不算「状态」变化。
    func sameState(as other: TypefreeUpdateInfo?) -> Bool {
        guard var o = other else { return false }
        var s = self
        s.downloadProgress = 0
        o.downloadProgress = 0
        return s == o
    }
}

extension Notification.Name {
    static let typefreeUpdateStateDidChange = Notification.Name("typefreeUpdateStateDidChange")
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

private struct TypefreeUpdateDialogModel {
    let badge: String
    let title: String
    let subtitle: String
    let versionText: String
    let notesTitle: String
    let notes: String
    let notesIsHTML: Bool          // 更新说明是 appcast 的 HTML → 富文本渲染；错误信息是纯文本
    let primaryTitle: String
    /// nil = 这一刻不需要副按钮。按钮照样建出来、先隐藏，状态一变（下载完 → 可以「稍后」）能直接显示，不用重建窗口。
    let secondaryTitle: String?
    let primaryEnabled: Bool
    let isError: Bool
    /// 0…1：显示下载进度条；nil：隐藏进度条。
    var progress: Double? = nil
}

/// 翻转坐标的容器：作为 NSScrollView 的 documentView 时内容从顶部开始显示。
private final class TopAnchoredView: NSView {
    override var isFlipped: Bool { true }
}

/// 卡片底部的渐隐遮罩：上端透明、下端是卡片底色，用来提示"下面还有内容"。不拦鼠标，滚动照常。
private final class BottomFadeView: NSView {
    private let gradient = CAGradientLayer()

    init(color: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        gradient.colors = [color.withAlphaComponent(0).cgColor, color.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)   // 顶端透明
        gradient.endPoint = CGPoint(x: 0.5, y: 0)     // 底端不透明
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class TypefreeUpdateDialogController: NSWindowController, NSWindowDelegate {
    /// 主按钮点完窗口是关是留，由调用方明说——不能再有"默认不关"这种隐式行为：
    /// 3.0.4 把「点了先关窗」改成「不关窗」时漏了「已是最新版本」那个「好」，结果窗口点不掉（Ray 2026-09-18）。
    /// 写成返回值，编译器会逼每个调用点表态。
    enum PrimaryOutcome { case close, keepOpen }

    private let onPrimary: () -> PrimaryOutcome
    private let onSecondary: () -> Void
    private let onClose: () -> Void

    init(model: TypefreeUpdateDialogModel,
         onPrimary: @escaping () -> PrimaryOutcome,
         onSecondary: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.onClose = onClose

        let isStatusOnly = model.badge == "OK"
        let window = NSPanel(
            // 高度随内容长了一点：多了 4 点进度条（含上下间距共 10 点）+ 更新说明卡片 200→230
            contentRect: NSRect(x: 0, y: 0, width: 468, height: isStatusOnly ? 352 : 506),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Typefree 更新"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.backgroundColor = .white
        window.isMovableByWindowBackground = true
        window.contentView = TypefreeUpdateDialogController.makeContent(model: model)
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }

        super.init(window: window)
        window.delegate = self
        wireButtons(in: window.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        centerOnScreen(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// NSWindow.center() 是"水平居中、垂直放在偏上约 1/3 处"，看起来就是没居中（Ray 2026-09-18）。
    /// 这里按主窗口所在屏幕的可用区域（去掉菜单栏和程序坞）正正地居中。
    private func centerOnScreen(_ window: NSWindow) {
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.minX + ((visible.width - size.width) / 2).rounded(),
            y: visible.minY + ((visible.height - size.height) / 2).rounded()
        ))
    }

    /// 实时刷新副标题、进度条和按钮文字，无需重建整个对话框——避免下载过程中窗口闪烁、丢焦点。
    func applyLiveState(subtitle: String, progress: Double?, primaryTitle: String, secondaryTitle: String?) {
        guard let root = window?.contentView else { return }
        Self.findSubtitle(in: root)?.stringValue = subtitle

        if let bar = Self.findProgressBar(in: root) {
            bar.isHidden = progress == nil
            if let progress { bar.doubleValue = max(0, min(1, progress)) * 100 }
        }
        if let primary = Self.findButton(role: .primary, in: root) {
            primary.setDisplayTitle(primaryTitle)
        }
        if let secondary = Self.findButton(role: .secondary, in: root) {
            secondary.isHidden = secondaryTitle == nil
            if let secondaryTitle { secondary.setDisplayTitle(secondaryTitle) }
        }
    }

    /// 安装已经开始：按钮不再可点，避免用户连点。
    func lockButtons() {
        guard let root = window?.contentView else { return }
        Self.findButton(role: .primary, in: root)?.isEnabled = false
        Self.findButton(role: .secondary, in: root)?.isHidden = true
    }

    private static func findSubtitle(in view: NSView) -> NSTextField? {
        if let tf = view as? NSTextField, tf.identifier?.rawValue == "typefree.update.subtitle" { return tf }
        for sub in view.subviews {
            if let found = findSubtitle(in: sub) { return found }
        }
        return nil
    }

    private static func findProgressBar(in view: NSView) -> NSProgressIndicator? {
        if let bar = view as? NSProgressIndicator, bar.identifier?.rawValue == "typefree.update.progress" { return bar }
        for sub in view.subviews {
            if let found = findProgressBar(in: sub) { return found }
        }
        return nil
    }

    private static func findButton(role: TypefreeUpdateButton.Role, in view: NSView) -> TypefreeUpdateButton? {
        if let button = view as? TypefreeUpdateButton, button.role == role { return button }
        for sub in view.subviews {
            if let found = findButton(role: role, in: sub) { return found }
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    /// 主按钮不再一律"先关窗口再干活"（Ray 2026-09-18：点完只看到窗口消失，以为更新好了，其实什么也没发生）。
    /// 下载／安装类动作留着窗口显示进度，其余动作照常关——由 onPrimary 的返回值决定。
    @objc private func primaryTapped() {
        if onPrimary() == .close { window?.close() }
    }

    /// 兜底：Esc 一定能关掉。这个窗口的红绿灯按钮是隐藏的，万一按钮逻辑再出岔子，用户不至于被困住。
    override func cancelOperation(_ sender: Any?) {
        window?.close()
    }

    @objc private func secondaryTapped() {
        window?.close()
        onSecondary()
    }

    private func wireButtons(in view: NSView?) {
        guard let view else { return }
        for subview in view.subviews {
            if let button = subview as? TypefreeUpdateButton {
                switch button.role {
                case .primary:
                    button.target = self
                    button.action = #selector(primaryTapped)
                case .secondary:
                    button.target = self
                    button.action = #selector(secondaryTapped)
                }
            }
            wireButtons(in: subview)
        }
    }

    private static func makeContent(model: TypefreeUpdateDialogModel) -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(hex: 0xFFFFFF).cgColor
        let isStatusOnly = model.badge == "OK"
        let margin: CGFloat = 28

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let logo = makeWaveformMark(box: 30, corner: 8)
        let brand = label("Typefree", size: 13.5, weight: .semibold, color: NSColor(hex: 0x111113))
        header.addSubview(logo)
        header.addSubview(brand)
        let trailingHeaderView: NSView = {
            guard !isStatusOnly else { return brand }
            let badge = makeBadge(model.badge, isError: model.isError)
            header.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: brand.trailingAnchor, constant: 8),
                badge.centerYAnchor.constraint(equalTo: brand.centerYAnchor)
            ])
            return badge
        }()
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 32),
            logo.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            logo.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            brand.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            brand.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            trailingHeaderView.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor)
        ])

        let title = label(model.title, size: 22, weight: .semibold, color: NSColor(hex: 0x111113))
        title.lineBreakMode = .byTruncatingTail
        let subtitle = label(model.subtitle, size: 13, weight: .regular, color: NSColor(hex: 0x686970))
        subtitle.maximumNumberOfLines = 0
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.identifier = NSUserInterfaceItemIdentifier("typefree.update.subtitle")   // 供实时刷新进度定位

        let versionPill = makeVersionPill(model.versionText)

        let notesCard = NSView()
        notesCard.wantsLayer = true
        notesCard.layer?.cornerRadius = 10
        notesCard.layer?.backgroundColor = NSColor(hex: 0xF6F6F7).cgColor
        notesCard.translatesAutoresizingMaskIntoConstraints = false

        let notesTitle = label(model.notesTitle, size: 12.5, weight: .semibold, color: NSColor(hex: 0x333337))
        let notesBody = NSTextField(wrappingLabelWithString: model.notes)
        notesBody.font = .systemFont(ofSize: 12.5, weight: .regular)
        notesBody.textColor = NSColor(hex: 0x66676E)
        notesBody.maximumNumberOfLines = 0
        notesBody.translatesAutoresizingMaskIntoConstraints = false
        // 更新说明按 HTML 富文本渲染（小标题/段落/要点分层，与「更新历史」面板同一套排版）；
        // 之前压成纯文本，一版说明糊成一坨。渲染失败回落纯文本。
        if model.notesIsHTML,
           let attr = ReleaseNotesRenderer.attributed(fromHTML: model.notes,
                                                      bodyColor: NSColor(hex: 0x66676E),
                                                      headingColor: NSColor(hex: 0x1F1F23),
                                                      fontSize: 12.5) {
            notesBody.attributedStringValue = attr
        }

        // 文档视图用翻转坐标（原点在左上）：否则内容超出一屏时 NSScrollView 默认停在底部，
        // 用户第一眼看到的是最后两段。
        let notesDoc = TopAnchoredView()
        notesDoc.translatesAutoresizingMaskIntoConstraints = false
        notesDoc.addSubview(notesBody)

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = !isStatusOnly
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = notesDoc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        notesCard.addSubview(notesTitle)
        notesCard.addSubview(scroll)
        // 更新说明超出一屏时底部加渐隐，提示"下面还有"——原先内容正好从半行处被切断，看着像排版坏了（Ray 2026-09-18）
        let fade = BottomFadeView(color: NSColor(hex: 0xF6F6F7))
        fade.isHidden = isStatusOnly
        notesCard.addSubview(fade)

        NSLayoutConstraint.activate([
            notesCard.heightAnchor.constraint(equalToConstant: isStatusOnly ? 96 : 230),
            fade.leadingAnchor.constraint(equalTo: notesCard.leadingAnchor, constant: 1),
            fade.trailingAnchor.constraint(equalTo: notesCard.trailingAnchor, constant: -1),
            fade.bottomAnchor.constraint(equalTo: notesCard.bottomAnchor, constant: -1),
            fade.heightAnchor.constraint(equalToConstant: 22),
            notesTitle.leadingAnchor.constraint(equalTo: notesCard.leadingAnchor, constant: 14),
            notesTitle.topAnchor.constraint(equalTo: notesCard.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: notesCard.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: notesCard.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: notesTitle.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: notesCard.bottomAnchor, constant: -12),
            // 跟 contentView 而不是 scroll 本身：系统「始终显示滚动条」时滚动条占位，
            // 跟 scroll 等宽会让最右边几个字压在滚动条底下被截掉。
            notesDoc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            notesBody.leadingAnchor.constraint(equalTo: notesDoc.leadingAnchor),
            notesBody.trailingAnchor.constraint(equalTo: notesDoc.trailingAnchor),
            notesBody.topAnchor.constraint(equalTo: notesDoc.topAnchor),
            notesDoc.bottomAnchor.constraint(equalTo: notesBody.bottomAnchor)
        ])

        // 下载进度条：一直在布局里（高 4 点），不下载时隐藏，省得状态一变就要重排窗口。
        let progressBar = NSProgressIndicator()
        progressBar.identifier = NSUserInterfaceItemIdentifier("typefree.update.progress")
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = (model.progress ?? 0) * 100
        progressBar.isHidden = model.progress == nil
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        // 副按钮常驻（不需要时隐藏）：下载完要从「放到后台」变成「安装并重启 / 稍后」，不重建窗口也能切
        let secondary = TypefreeUpdateButton(title: model.secondaryTitle ?? "稍后", role: .secondary)
        secondary.isHidden = model.secondaryTitle == nil
        let primary = TypefreeUpdateButton(title: model.primaryTitle, role: .primary)
        primary.isEnabled = model.primaryEnabled

        [header, title, subtitle, progressBar, versionPill, notesCard, primary, secondary].forEach(root.addSubview)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),

            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            title.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),

            progressBar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 10),
            progressBar.heightAnchor.constraint(equalToConstant: 4),

            versionPill.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            versionPill.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12),

            notesCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            notesCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            notesCard.topAnchor.constraint(equalTo: versionPill.bottomAnchor, constant: 18),

            primary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            primary.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            primary.widthAnchor.constraint(greaterThanOrEqualToConstant: isStatusOnly ? 96 : 118),

            secondary.trailingAnchor.constraint(equalTo: primary.leadingAnchor, constant: -10),
            secondary.centerYAnchor.constraint(equalTo: primary.centerYAnchor),
            secondary.widthAnchor.constraint(greaterThanOrEqualToConstant: 92)
        ])

        return root
    }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private static func makeBadge(_ text: String, isError: Bool) -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        let color = isError ? NSColor(hex: 0xC24545) : (text == "OK" ? NSColor(hex: 0x2E8762) : NSColor(hex: 0xE5484D))
        badge.layer?.backgroundColor = color.cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        let textLabel = label(text, size: 9.5, weight: .bold, color: .white)
        textLabel.alignment = .center
        badge.addSubview(textLabel)
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 18),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
            textLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 7),
            textLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -7),
            textLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor, constant: -0.5)
        ])
        return badge
    }

    private static func makeVersionPill(_ text: String) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 8
        pill.layer?.backgroundColor = NSColor(hex: 0xF2F2F3).cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false
        let label = label(text, size: 12.5, weight: .medium, color: NSColor(hex: 0x3F3F43))
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])
        return pill
    }

    static func makeWaveformMark(box: CGFloat, corner: CGFloat) -> NSView {
        let bars: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (11, 10, 37.2, 25.6, 5), (28, 10, 26, 48, 5), (45, 10, 18, 64, 5),
            (62, 10, 29.2, 41.6, 5), (79, 10, 38.8, 22.4, 5)
        ]
        let mark = box * 0.68
        let off = (box - mark) / 2
        let scale = mark / 100.0
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = corner
        view.layer?.backgroundColor = NSColor(hex: 0x111113).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: box),
            view.heightAnchor.constraint(equalToConstant: box)
        ])
        for (x, w, y, h, r) in bars {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.frame = CGRect(x: off + x * scale, y: box - off - (y + h) * scale, width: w * scale, height: h * scale)
            bar.cornerRadius = r * scale
            view.layer?.addSublayer(bar)
        }
        return view
    }
}

private final class TypefreeUpdateButton: NSButton {
    enum Role { case primary, secondary }

    let role: Role
    private var hovering = false

    init(title: String, role: Role) {
        self.role = role
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet { applyStyle() }
    }

    /// 就地改按钮文字（applyStyle 会把 title 重新画成 attributedTitle，所以不能只设 title）
    func setDisplayTitle(_ newTitle: String) {
        guard title != newTitle else { return }
        title = newTitle
        applyStyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyStyle()
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private func applyStyle() {
        let titleColor: NSColor
        let background: NSColor
        let border: NSColor
        if !isEnabled {
            titleColor = NSColor(hex: 0xA0A1A7)
            background = NSColor(hex: 0xEFEFF0)
            border = .clear
        } else {
            switch role {
            case .primary:
                titleColor = .white
                background = hovering ? NSColor(hex: 0x303033) : NSColor(hex: 0x111113)
                border = .clear
            case .secondary:
                titleColor = NSColor(hex: 0x242428)
                background = hovering ? NSColor(hex: 0xF2F2F3) : .white
                border = NSColor.black.withAlphaComponent(0.14)
            }
        }

        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: titleColor
        ])
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = role == .secondary && isEnabled ? 1 : 0
    }
}

/// 每天一次的「有可用更新」小提醒窗（Ray 2026-09-22，照 Claude 桌面版那个尺寸）：
/// 大窗（发现新版本 + 完整更新内容）留给用户主动点「检查更新…」看；主动打断用户的提醒只放一句话和两个按钮。
/// 「看看改了什么」才打开大窗。锁浅色（弹窗类不跟夜间模式，Ray 的规矩）。
@MainActor
private final class TypefreeUpdateReminderController: NSWindowController, NSWindowDelegate {
    private let onInstall: () -> Void
    private let onShowDetails: () -> Void
    private let onClose: () -> Void
    private var subtitle: NSTextField!
    private var primary: TypefreeUpdateButton!
    private var secondary: TypefreeUpdateButton!
    private var detailsButton: NSButton!
    private var closeButton: NSButton!

    init(versionText: String, onInstall: @escaping () -> Void, onShowDetails: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onInstall = onInstall
        self.onShowDetails = onShowDetails
        self.onClose = onClose
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 164),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Typefree 更新"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.backgroundColor = .white
        window.isMovableByWindowBackground = true
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent(versionText: versionText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: visible.minX + ((visible.width - size.width) / 2).rounded(),
                y: visible.minY + ((visible.height - size.height) / 2).rounded()
            ))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 点了「重启更新」：窗口留着显示状态，按钮全部失效，避免连点。
    func showInstalling() {
        subtitle.stringValue = "正在安装并重启…"
        primary.isEnabled = false
        secondary.isHidden = true
        detailsButton.isHidden = true
        closeButton.isHidden = true
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    override func cancelOperation(_ sender: Any?) { window?.close() }

    @objc private func installTapped() { onInstall() }
    @objc private func laterTapped() { window?.close() }
    @objc private func detailsTapped() {
        window?.close()
        onShowDetails()
    }

    private func makeContent(versionText: String) -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(hex: 0xFFFFFF).cgColor
        let margin: CGFloat = 24

        let logo = TypefreeUpdateDialogController.makeWaveformMark(box: 26, corner: 7)
        let title = TypefreeUpdateDialogController.label("有可用更新", size: 15, weight: .semibold, color: NSColor(hex: 0x111113))

        closeButton = NSButton()
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.focusRingType = .none
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        closeButton.contentTintColor = NSColor(hex: 0x8E8E93)
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(laterTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setAccessibilityLabel("关闭")

        subtitle = TypefreeUpdateDialogController.label("\(versionText) 已在后台下载好，重启即可完成更新。", size: 13, weight: .regular, color: NSColor(hex: 0x686970))
        subtitle.maximumNumberOfLines = 0
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.identifier = NSUserInterfaceItemIdentifier("typefree.update.reminder.subtitle")

        detailsButton = NSButton()
        detailsButton.isBordered = false
        detailsButton.bezelStyle = .regularSquare
        detailsButton.focusRingType = .none
        detailsButton.attributedTitle = NSAttributedString(string: "看看改了什么", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(hex: 0x8E8E93),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        detailsButton.target = self
        detailsButton.action = #selector(detailsTapped)
        detailsButton.translatesAutoresizingMaskIntoConstraints = false

        secondary = TypefreeUpdateButton(title: "稍后", role: .secondary)
        secondary.target = self
        secondary.action = #selector(laterTapped)
        primary = TypefreeUpdateButton(title: "重启更新", role: .primary)
        primary.target = self
        primary.action = #selector(installTapped)
        primary.keyEquivalent = "\r"

        [logo, title, closeButton, subtitle, detailsButton, secondary, primary].forEach(root.addSubview)

        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            logo.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: logo.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -(margin - 6)),
            closeButton.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            subtitle.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 14),

            primary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            primary.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
            primary.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            secondary.trailingAnchor.constraint(equalTo: primary.leadingAnchor, constant: -10),
            secondary.centerYAnchor.constraint(equalTo: primary.centerYAnchor),

            detailsButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin - 2),
            detailsButton.centerYAnchor.constraint(equalTo: primary.centerYAnchor)
        ])
        return root
    }
}

@MainActor
private final class TypefreeUpdateUserDriver: NSObject, SPUUserDriver {
    private weak var owner: AppDelegate?
    private var dialogController: TypefreeUpdateDialogController?
    private var reminderController: TypefreeUpdateReminderController?
    private var userInitiatedCheck = false
    private var presentDetailsWhenReady = false
    private var autoInstallOnReady = false   // 用户主动更新：下载完直接安装重启（省二次点击）
    private var expectedDownloadLength: UInt64 = 0
    private var receivedDownloadLength: UInt64 = 0
    private var foundUpdateReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyInstallReply: ((SPUUserUpdateChoice) -> Void)?
    private var installOnQuitHandler: (() -> Void)?
    private(set) var updateInfo: TypefreeUpdateInfo? {
        didSet {
            // 只在「状态」变化时广播：设置窗收到后会整个重建侧栏（含解密全部历史数行数）。
            // 下载进度每收到一块数据就更新一次，若也广播，几十 MB 的 DMG 下载期间
            // 会把设置窗主线程刷成转圈；进度由 refreshLiveDialog 单独刷到弹窗副标题。
            let changed: Bool
            switch (oldValue, updateInfo) {
            case (nil, nil): changed = false
            case let (old?, new?): changed = !new.sameState(as: old)
            default: changed = true
            }
            if changed {
                NotificationCenter.default.post(name: .typefreeUpdateStateDidChange, object: nil)
            }
        }
    }

    init(owner: AppDelegate) {
        self.owner = owner
        super.init()
    }

    func beginUserInitiatedCheck() {
        userInitiatedCheck = true
        presentDetailsWhenReady = false
    }

    func installPendingUpdate() {
        if let readyInstallReply {
            self.readyInstallReply = nil
            readyInstallReply(.install)
        } else if let installOnQuitHandler {
            self.installOnQuitHandler = nil
            installOnQuitHandler()
        } else if let foundUpdateReply {
            self.foundUpdateReply = nil
            foundUpdateReply(.install)
        } else if let url = updateInfo?.infoURL {
            NSWorkspace.shared.open(url)
        }
    }

    func presentUpdateDetails() {
        reminderController?.close()
        guard let info = updateInfo else {
            owner?.checkForUpdates(nil)
            return
        }

        let isError = info.errorMessage != nil
        let model = TypefreeUpdateDialogModel(
            badge: isError ? "ERROR" : "NEW",
            title: isError ? "更新检查遇到问题" : "发现新版本",
            subtitle: updateSummary(for: info),
            versionText: versionText(for: info),
            notesTitle: isError ? "错误信息" : "更新内容",
            notes: notesText(for: info),
            notesIsHTML: !isError,
            primaryTitle: primaryButtonTitle(for: info),
            secondaryTitle: secondaryButtonTitle(for: info),
            primaryEnabled: true,
            isError: isError,
            progress: (info.isDownloading && !info.isReadyToInstall) ? info.downloadProgress : nil
        )
        // ⚠ 闭包里必须读「当下」的状态，不能用建窗口时捕获的 info：窗口不再点一下就关，
        // 下载完按钮会就地从「放到后台」变成「安装并重启」，用旧快照会按下载中的分支走（Ray 2026-09-18）。
        showDialog(model: model) { [weak self] in
            guard let self, let current = self.updateInfo else { return .close }
            if current.errorMessage != nil {
                self.owner?.checkForUpdates(nil)
                return .close
            }
            if current.isDownloading && !current.isReadyToInstall {
                return .close   // 「放到后台」：关掉窗口，onClose 里转成不打扰模式
            }
            if current.infoURL != nil && self.readyInstallReply == nil && self.foundUpdateReply == nil && self.installOnQuitHandler == nil {
                if let url = current.infoURL { NSWorkspace.shared.open(url) }
                return .close
            }
            // 「立即更新」/「安装并重启」：窗口留着，进度和状态就地刷新，用户看得见事情在发生
            self.dialogController?.lockButtons()
            self.refreshLiveDialog(installing: current.isReadyToInstall)
            self.installPendingUpdate()
            return .keepOpen
        }
    }

    func captureInstallOnQuit(for item: SUAppcastItem, handler: @escaping () -> Void) {
        installOnQuitHandler = handler
        updateInfo = makeInfo(from: item, isReady: true, isDownloading: false)
        startReadyReminder()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, automaticUpdateDownloading: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiatedCheck = true
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let infoOnly = appcastItem.isInformationOnlyUpdate
        let shouldPresentDetails = userInitiatedCheck
        updateInfo = makeInfo(from: appcastItem, isReady: state.stage != .notDownloaded || infoOnly, isDownloading: state.stage == .notDownloaded && !infoOnly)

        if infoOnly {
            foundUpdateReply = { _ in reply(.dismiss) }
            if shouldPresentDetails { presentUpdateDetails() }
            userInitiatedCheck = false
            return
        }

        switch state.stage {
        case .notDownloaded:
            presentDetailsWhenReady = shouldPresentDetails
            if shouldPresentDetails {
                // 用户主动检查：立刻弹进度对话框，下载完自动安装并重启（省去干等 + 二次点击）。
                autoInstallOnReady = true
                updateInfo?.isDownloading = true
                reply(.install)
                presentUpdateDetails()
            } else {
                // 后台自动发现：静默下载/解包，就绪后弹一次提醒（见 startReadyReminder），之后每天一次。
                reply(.install)
            }
        case .downloaded, .installing:
            foundUpdateReply = reply
            updateInfo?.isReadyToInstall = true
            updateInfo?.isDownloading = false
            if shouldPresentDetails { presentUpdateDetails() } else { startReadyReminder() }
        @unknown default:
            foundUpdateReply = reply
        }
        userInitiatedCheck = false
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard var info = updateInfo else { return }
        let text: String
        if let encodingName = downloadData.textEncodingName,
           let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)) as UInt?,
           let decoded = String(data: downloadData.data as Data, encoding: String.Encoding(rawValue: encoding)) {
            text = decoded
        } else {
            text = String(data: downloadData.data as Data, encoding: .utf8) ?? info.releaseNotes
        }
        info = TypefreeUpdateInfo(
            title: info.title,
            displayVersion: info.displayVersion,
            buildVersion: info.buildVersion,
            releaseNotes: text,
            infoURL: info.infoURL,
            isReadyToInstall: info.isReadyToInstall,
            isDownloading: info.isDownloading,
            downloadProgress: info.downloadProgress,
            errorMessage: info.errorMessage
        )
        updateInfo = info
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // appcast 里的内联说明仍可展示；外链失败不打断更新。
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        updateInfo = nil
        if userInitiatedCheck {
            let model = TypefreeUpdateDialogModel(
                badge: "OK",
                title: "已是最新版本",
                subtitle: "当前没有可安装的新版本。",
                versionText: currentVersionText(),
                notesTitle: "更新状态",
                notes: "Typefree 会每天自动检查一次；有新版本时会先在后台下载好，再提醒你安装。",
                notesIsHTML: false,
                primaryTitle: "好",
                secondaryTitle: nil,
                primaryEnabled: true,
                isError: false
            )
            showDialog(model: model) { .close }   // 「好」＝纯关闭
        }
        userInitiatedCheck = false
        presentDetailsWhenReady = false
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        let message = (error as NSError).localizedDescription
        updateInfo = TypefreeUpdateInfo(
            title: "更新检查失败",
            displayVersion: "",
            buildVersion: "",
            releaseNotes: "",
            infoURL: nil,
            isReadyToInstall: false,
            isDownloading: false,
            errorMessage: message
        )
        if userInitiatedCheck {
            presentUpdateDetails()
        }
        userInitiatedCheck = false
        presentDetailsWhenReady = false
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedDownloadLength = 0
        receivedDownloadLength = 0
        if var info = updateInfo {
            info.isDownloading = true
            info.isReadyToInstall = false
            info.downloadProgress = 0
            updateInfo = info
        }
        refreshLiveDialog()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedDownloadLength += length
        if var info = updateInfo {   // 单次赋值只发一条状态通知
            if expectedDownloadLength > 0 {
                info.downloadProgress = min(1.0, Double(receivedDownloadLength) / Double(expectedDownloadLength))
            }
            info.isDownloading = true
            updateInfo = info
        }
        refreshLiveDialog()
    }

    func showDownloadDidStartExtractingUpdate() {
        if var info = updateInfo {
            info.isDownloading = true
            info.downloadProgress = 1.0
            updateInfo = info
        }
        refreshLiveDialog(extracting: true)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        updateInfo?.isDownloading = true
        refreshLiveDialog(extracting: true)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        updateInfo?.isDownloading = false
        updateInfo?.isReadyToInstall = true
        if autoInstallOnReady {
            // 用户主动更新：下载完直接安装并重启，不再让用户点第二次。
            autoInstallOnReady = false
            presentDetailsWhenReady = false
            userInitiatedCheck = false
            refreshLiveDialog(installing: true)
            reply(.install)
            return
        }
        readyInstallReply = reply
        if userInitiatedCheck || presentDetailsWhenReady {
            presentUpdateDetails()
            userInitiatedCheck = false
            presentDetailsWhenReady = false
            return
        }
        // 后台静默下载好了：主动提醒一次（每天最多一次），别再只靠主窗口那个小红点。
        startReadyReminder()
    }

    // MARK: - 下载就绪后的每日提醒（Ray 2026-09-22）
    //
    // 以前后台下载完只在主窗口左上角亮个小红点，不开主窗口的人永远看不到，一直用旧版。
    // 现在：就绪后立刻弹一次「发现新版本」窗（安装并重启 / 稍后）；点了稍后，之后每天再弹一次，
    // 直到装上为止。录音或出字过程中不弹（抢焦点会打断用户），过两分钟再试。
    // 用户自己点「检查更新…」弹出的窗不算提醒，不计时间。

    private static let readyReminderDefaultsKey = "updateReadyReminderLastShown"   // [版本号: 上次提醒时间]
    private static let readyReminderInterval: TimeInterval = 23 * 3600               // 每天一次；留 1 小时余量给整点定时器
    private static let readyReminderBusyRetry: TimeInterval = 2 * 60
    private var readyReminderTimer: Timer?
    private var readyReminderRetry: DispatchWorkItem?

    private func startReadyReminder() {
        if readyReminderTimer == nil {
            let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
                self?.presentReadyReminderIfDue()
            }
            timer.tolerance = 300
            RunLoop.main.add(timer, forMode: .common)
            readyReminderTimer = timer
        }
        presentReadyReminderIfDue()
    }

    private func stopReadyReminder() {
        readyReminderTimer?.invalidate()
        readyReminderTimer = nil
        readyReminderRetry?.cancel()
        readyReminderRetry = nil
    }

    private func presentReadyReminderIfDue() {
        readyReminderRetry?.cancel()
        readyReminderRetry = nil
        guard let info = updateInfo, info.isReadyToInstall, info.errorMessage == nil else { return }
        guard dialogController == nil, reminderController == nil else { return }   // 窗已经开着（比如用户自己点开的），不重复弹

        let key = info.buildVersion.isEmpty ? info.displayVersion : info.buildVersion
        let shown = UserDefaults.standard.dictionary(forKey: Self.readyReminderDefaultsKey) as? [String: Date] ?? [:]
        if let last = shown[key], Date().timeIntervalSince(last) < Self.readyReminderInterval { return }

        if owner?.isBusyForUpdateReminder() == true {
            let retry = DispatchWorkItem { [weak self] in self?.presentReadyReminderIfDue() }
            readyReminderRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyReminderBusyRetry, execute: retry)
            return
        }

        UserDefaults.standard.set([key: Date()], forKey: Self.readyReminderDefaultsKey)   // 只留当前版本，旧版本的记录顺手清掉
        presentReadyReminder(versionText: info.displayVersion.isEmpty ? "新版本" : "Typefree \(info.displayVersion)")
    }

    private func presentReadyReminder(versionText: String) {
        let controller = TypefreeUpdateReminderController(
            versionText: versionText,
            onInstall: { [weak self] in
                guard let self else { return }
                self.reminderController?.showInstalling()
                self.installPendingUpdate()
            },
            onShowDetails: { [weak self] in self?.presentUpdateDetails() },
            onClose: { [weak self] in self?.reminderController = nil }
        )
        reminderController = controller
        controller.show()
    }

    /// 实时刷新当前对话框副标题（下载中显示百分比，解包/安装显示对应状态）。对话框没开则无操作。
    private func refreshLiveDialog(installing: Bool = false, extracting: Bool = false) {
        guard let controller = dialogController, let info = updateInfo else { return }
        let text: String
        if installing {
            text = "下载完成，正在安装并重启…"
        } else if extracting {
            text = "下载完成，正在准备安装…"
        } else if info.isReadyToInstall {
            text = "版本 \(info.displayVersion) 已准备好，可以安装并重启。"
        } else if info.isDownloading {
            let pct = Int((info.downloadProgress * 100).rounded())
            text = info.downloadProgress > 0 ? "正在下载更新 \(pct)%…" : "正在开始下载…"
        } else {
            text = updateSummary(for: info)
        }
        let downloading = info.isDownloading && !info.isReadyToInstall && !installing && !extracting
        controller.applyLiveState(
            subtitle: text,
            progress: downloading ? info.downloadProgress : nil,
            primaryTitle: (installing || extracting) ? "安装并重启" : primaryButtonTitle(for: info),
            secondaryTitle: (installing || extracting) ? nil : secondaryButtonTitle(for: info)
        )
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        stopReadyReminder()
        updateInfo?.isReadyToInstall = false
        updateInfo?.isDownloading = false
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        stopReadyReminder()
        acknowledgement()
        updateInfo = nil
    }

    func dismissUpdateInstallation() {
        // Sparkle may call this after aborting/finishing. Keep downloaded-update info visible
        // until install starts so the NEW badge does not blink away during a deferred install.
    }

    func showUpdateInFocus() {
        presentUpdateDetails()
    }

    private func makeInfo(from item: SUAppcastItem, isReady: Bool, isDownloading: Bool) -> TypefreeUpdateInfo {
        TypefreeUpdateInfo(
            title: item.title ?? "Typefree 新版本",
            displayVersion: item.displayVersionString,
            buildVersion: item.versionString,
            releaseNotes: Self.releaseNotes(from: item),
            infoURL: item.infoURL,
            isReadyToInstall: isReady,
            isDownloading: isDownloading,
            errorMessage: nil
        )
    }

    private func updateSummary(for info: TypefreeUpdateInfo) -> String {
        if let error = info.errorMessage { return error }
        if info.isReadyToInstall {
            return "版本 \(info.displayVersion) 已准备好，可以安装并重启。"
        }
        if info.isDownloading {
            let pct = Int((info.downloadProgress * 100).rounded())
            return info.downloadProgress > 0
                ? "正在下载更新 \(pct)%，下载完成后会自动安装并重启。"
                : "正在下载更新，下载完成后会自动安装并重启。"
        }
        return "发现版本 \(info.displayVersion)。"
    }

    /// 按钮上写"要发生什么"，不写状态（Ray 2026-09-18：下载中时主按钮写着「稍后」，点了等于取消自动安装，
    /// 但窗口一关什么反馈都没有，用户以为已经更新好了）。状态归副标题和进度条管。
    private func primaryButtonTitle(for info: TypefreeUpdateInfo) -> String {
        if info.errorMessage != nil { return "重新检查" }
        if info.infoURL != nil && readyInstallReply == nil && foundUpdateReply == nil && installOnQuitHandler == nil {
            return "查看详情"
        }
        if info.isReadyToInstall { return "安装并重启" }
        return info.isDownloading ? "放到后台" : "立即更新"
    }

    /// 下载中只留「放到后台」一个按钮（再给个「稍后」没意义）；其余状态都配「稍后」。
    private func secondaryButtonTitle(for info: TypefreeUpdateInfo) -> String? {
        (info.isDownloading && !info.isReadyToInstall) ? nil : "稍后"
    }

    private func showDialog(model: TypefreeUpdateDialogModel,
                            onPrimary: @escaping () -> TypefreeUpdateDialogController.PrimaryOutcome,
                            onSecondary: @escaping () -> Void = {}) {
        dialogController?.close()
        let controller = TypefreeUpdateDialogController(
            model: model,
            onPrimary: onPrimary,
            onSecondary: onSecondary,
            onClose: { [weak self] in
                guard let self else { return }
                self.dialogController = nil
                // 用户在下载中关掉进度窗（点「稍后」）→ 转为后台温和模式，不再自动重启，只留 NEW 徽章。
                if self.updateInfo?.isReadyToInstall == false, self.updateInfo?.isDownloading == true {
                    self.autoInstallOnReady = false
                    self.presentDetailsWhenReady = false
                }
            }
        )
        dialogController = controller
        controller.show()
    }

    private func versionText(for info: TypefreeUpdateInfo) -> String {
        if info.displayVersion.isEmpty {
            return currentVersionText()
        }
        if info.buildVersion.isEmpty || info.buildVersion == info.displayVersion {
            return "版本 \(info.displayVersion)"
        }
        return "版本 \(info.displayVersion)（\(info.buildVersion)）"
    }

    private func currentVersionText() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "本地开发版"
        return "当前版本 \(version)"
    }

    private func notesText(for info: TypefreeUpdateInfo) -> String {
        if let error = info.errorMessage, !error.isEmpty {
            return error
        }
        let releaseNotes = info.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return releaseNotes.isEmpty ? "这次更新包含体验改进和问题修复。" : releaseNotes
    }

    private static func releaseNotes(from item: SUAppcastItem) -> String {
        if let desc = item.itemDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            return desc   // 保留 HTML 原文，弹窗用 ReleaseNotesRenderer 富文本渲染
        }
        if let url = item.releaseNotesURL {
            return "完整更新内容：\(url.absoluteString)"
        }
        return "这次更新包含体验改进和问题修复。"
    }

}

class AppDelegate: NSObject, NSApplicationDelegate, SettingsWindowDelegate, SPUUpdaterDelegate {
    var statusBar: StatusBarController!
    var overlayWindow: OverlayWindow!
    var audioRecorder: AudioRecorder!
    var cloudTranscriber: CloudASRTranscriber!
    var aiPolisher: AIPolisher!
    var hotkeyManager: HotkeyManager!
    /// 鼠标长按说话（实验功能，默认关闭）；和 hotkeyManager 同生命周期，同样需要辅助功能权限
    var mouseHoldToTalkManager: MouseHoldToTalkManager?
    /// 本次输出应用了语音口令（如英文输出）：交付后提示一次
    private var pendingOutputLanguageHint: String?
    /// 「长按问 AI」：本次录音不是输入而是提问
    private var voiceQuestionMode = false
    /// 在回答面板上长按发起的续聊（带本话题上下文，追加在面板里）
    private var voiceQuestionFollowUp = false
    private var voiceQuestionAnchor: NSPoint = .zero
    /// 鼠标长按问 AI：录音已开始、还没听到用户开口。开口前不接管鼠标：拖动 = 选字，悄悄撤销；
    /// 松手照常识别（没判断出开口不代表没说话），识别不出话才悄悄收起、不提示
    private var askAwaitingSpeech = false
    /// 「开口」判定：每次录音按这次最安静的一帧现定过线值，换麦、换环境都自适应（见 AskSpeechDetector）
    private var askSpeechDetector = AskSpeechDetector()
    /// 长按问 AI 这次录音的开始时刻：没判出开口就松手时，不足 1 秒的按住当误触丢掉
    private var askRecordingStartedAt: Date?
    private let answerPanel = AnswerPanel()
    var textDelivery: TextDelivery!
    var pipeline: VoicePolishPipeline!

    /// Sparkle 仍负责安全下载和安装；用户可见的更新入口由 Typefree 自己控制。
    private lazy var updateUserDriver = TypefreeUpdateUserDriver(owner: self)
    lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updateUserDriver, delegate: self)

    /// 菜单栏「检查更新…」转发到 Sparkle。
    @objc func checkForUpdates(_ sender: Any?) {
        updateUserDriver.beginUserInitiatedCheck()
        updater.checkForUpdates()
    }

    func pendingUpdateInfo() -> TypefreeUpdateInfo? {
        updateUserDriver.updateInfo
    }

    func showUpdateDetails(_ sender: Any?) {
        updateUserDriver.presentUpdateDetails()
    }

    func installPendingUpdate() {
        updateUserDriver.installPendingUpdate()
    }

    /// Sparkle 即将为安装更新而重启本 App。此刻若有 sheet（如激活弹窗）开着，会阻止退出，
    /// 先把所有附着的模态 sheet 收掉，确保能顺利退出 → 替换 → 重启。
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        dismissAllAttachedSheets()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        updateUserDriver.captureInstallOnQuit(for: item, handler: immediateInstallHandler)
        return true
    }

    private func dismissAllAttachedSheets() {
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
    }

    private var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            updateEscapeInterceptor()
        }
    }
    private lazy var escapeInterceptor: EscapeInterceptor = {
        let interceptor = EscapeInterceptor()
        interceptor.debugLog = { [weak self] msg in self?.debugLog(msg) }
        interceptor.onEscape = { [weak self] in
            guard let self else { return }
            if self.isRecording { self.cancelRecording() } else { self.cancelProcessing() }
        }
        return interceptor
    }()
    /// 工单 #1019：录音期间 Esc 取消；工单 #1024：识别 / 整理中（文字还没打出来）也能按 Esc 取消。按键都不传给前台 App。
    private var escapeInterceptorWanted = false
    private func updateEscapeInterceptor() {
        let wanted = isRecording || processingSamples != nil
        guard wanted != escapeInterceptorWanted else { return }
        escapeInterceptorWanted = wanted
        if wanted { escapeInterceptor.activate() } else { escapeInterceptor.deactivate() }
    }
    private var isProcessing = false
    /// 正在识别 / 整理的这段录音（听写才有；问 AI 不走这里）。非 nil 期间按 Esc 可取消，出字或报错后清空。
    private var processingSamples: [Float]? {
        didSet { updateEscapeInterceptor() }
    }
    private var processingStartedAt = Date()
    /// 每开始处理一段录音 +1；取消 / 放弃时也 +1，晚到的边录边发结果对不上号就丢掉
    private var processingGeneration = 0
    /// 识别阶段的总等待封顶（工单 #1024：网络卡住时以前每步干等一分钟、叠加重试近 3 分钟）
    private var recognitionWatchdog: DispatchWorkItem?
    /// 这次边录边发的会话：等太久放弃时，先把已识别出的前半段交给用户
    private var processingSession: StreamingTranscriptionSession?
    /// 只识别出了前半段：出字后提醒一次（后半截以前会悄悄丢掉）
    private var pendingPartialHint: String?
    private static let partialResultHint = "后半段没识别出来 · 整段录音在历史里，可点「···」→「重试」"
    /// 这次录音放过开始提示音没有：结束音只跟在开始音后面放（长按问 AI 没判出开口时两个都不放）
    private var didPlayStartCue = false

    /// 更新提醒弹窗要不要缓一缓：录音或出字过程中弹窗会抢焦点、打断用户。
    func isBusyForUpdateReminder() -> Bool { isRecording || isProcessing }
    private let debugLogQueue = DispatchQueue(label: "com.voicepolish.debug-log", qos: .utility)
    private let debugLogMaxBytes: UInt64 = 2 * 1024 * 1024
    private let debugLogPrivacyMigrationKey = "debugLogPrivacyMigrationV1"
    private var didReportMissingAccessibility = false
    private var didPromptForAccessibility = false
    private var axPollTimer: Timer?  // 辅助功能未授权时轮询，授权后立即接管快捷键（无需重启）
    private var trialMaxRecordingTimer: Timer?  // 试用录音封顶 5 分钟，到点自动停止转写已录内容
    private var streamingSession: StreamingTranscriptionSession?  // 边录边发：录音中提交已说完的段落
    private var streamingTimer: Timer?  // 录音中定时取样并 ingest
    private var streamingEnabled: Bool {  // 隐藏开关，出问题可不发版关闭
        VoicePolishConfig.shared.bool(forKey: "streaming_asr_enabled", defaultValue: true)
    }
    private var lastDeliveredText: String?
    /// 最近一次录音时前台的软件名（给反馈页当线索）
    private var lastRecordingTargetApp: String?
    private var supportPollTimer: Timer?
    private var pendingPolishWarning: String?  // 润色失败原因（额度用尽等），在文字投递后提醒一次
    private var pendingOverlayHide: DispatchWorkItem?  // 防止上一次错误的延时隐藏误杀新录音浮窗
    private var cancelledSamples: [Float]?  // 误点叉号的录音暂存（撤销窗口期内可重新识别）
    /// 暂存的这段是不是「问 AI」的录音：撤销时要重新去问 AI，而不是当普通文字打出来
    private var cancelledWasAsk = false
    private var cancelledSamplesTimer: Timer?  // 撤销窗口到期后清暂存，不让大段音频常驻内存
    private var processingMode: ProcessingMode = {
        ProcessingMode.migrateUserDefaultsIfNeeded()
        let raw = UserDefaults(suiteName: ProcessingMode.appGroupSuiteName)?
            .string(forKey: ProcessingMode.userDefaultsKey)
            ?? UserDefaults.standard.string(forKey: ProcessingMode.userDefaultsKey)
            ?? ""
        let stored = ProcessingMode(rawValue: raw) ?? .cloudOnly
        // omni 已从 UI 下线：始终以云端直出运行（旧的 omni 设置按 cloudOnly 处理）
        return stored == .omni ? .cloudOnly : stored
    }()
    private var isAutoTermCorrectionLearningEnabled: Bool {
        VoicePolishConfig.shared.bool(forKey: "term_corrections_auto_learn_enabled", defaultValue: true)
    }

    private func currentFrontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知"
    }

    func debugLog(_ message: String) {
        let logFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePolish.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let maxBytes = debugLogMaxBytes
        debugLogQueue.async {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)

            let attributes = try? fileManager.attributesOfItem(atPath: logFile.path)
            let currentBytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            if currentBytes + UInt64(data.count) > maxBytes {
                try? fileManager.removeItem(at: logFile)
            }

            if fileManager.fileExists(atPath: logFile.path),
               let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logFile, options: .atomic)
            }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFile.path)
        }
    }

    /// 3.0.1 起录音浮窗默认「墨黑·白波」（Ray 9-15：新装和升级的用户都统一用这个）。
    /// 升级用户做一次性重置——之前选过「彩色（Siri）」的也回到墨黑，想换回去在「设置 → 录音浮窗」里点一下就行。
    private func resetOverlayStyleToMonoOnce() {
        let flag = "overlayStyleResetToMonoV1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        defaults.removeObject(forKey: OverlayStyle.userDefaultsKey)   // 空 = 默认墨黑
        defaults.set(true, forKey: flag)
    }

    private func removeLegacyPlaintextDebugLogIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: debugLogPrivacyMigrationKey) else { return }
        let logFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePolish.log")
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: logFile.path) {
                try fileManager.removeItem(at: logFile)
            }
            defaults.set(true, forKey: debugLogPrivacyMigrationKey)
        } catch {
            return
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 用户关了「在 Dock 中显示」：在 Dock 图标出现前就切走，免得启动时闪一下
        DockIcon.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        removeLegacyPlaintextDebugLogIfNeeded()
        resetOverlayStyleToMonoOnce()
        debugLog("App launched")
        CuePlayer.shared.preload()   // 提示音启动时合成好，第一次录音不卡

        // 配置存不下来时（文件夹权限不对、文件损坏）要在日志里留痕，否则用户只看到「每次都要重新设置」。
        VoicePolishConfig.shared.debugLog = { [weak self] msg in self?.debugLog(msg) }

        // 启动早期：把明文 config 残留的 API key 收敛进钥匙串（幂等、fail-closed）。
        VoicePolishConfig.shared.reconcileSecrets()

        // 首次启动（含老用户首次升到此版本）默认开启「开机自启动」：只自动登记这一次，
        // 之后完全尊重用户在设置开关 / 系统设置里的后续选择，不再自作主张。
        LaunchAtLogin.applyDefaultIfFirstLaunch()

        // 锁定浅色外观：仅做了「系统原生灰」浅色主题，夜间模式暂未打磨，
        // 强制全 App 用 aqua（自定义主题 + 原生控件都跟随），避免系统切暗色后样式糟糕。
        NSApp.appearance = NSAppearance(named: .aqua)

        // 补一个标准主菜单：没有它，Cmd+C/V/X/A 等编辑快捷键无法分发到输入框
        // （之前只能靠右键菜单粘贴）。
        setupMainMenu()

        // 握手时告诉服务器「这台填了自己的 Key」，运营后台才分得清自带 Key 与试用用户（只是个布尔值）
        TrialManager.ownKeyConfiguredProvider = { [weak self] in self?.cloudTranscriber.isConfigured() ?? false }

        do {
            try updater.start()
            if updater.automaticallyChecksForUpdates,
               updater.allowsAutomaticUpdates,
               !updater.automaticallyDownloadsUpdates {
                updater.automaticallyDownloadsUpdates = true
            }
            // Info.plist 中仍保持每天检查一次；这里不额外强制每次启动弹检查。
            debugLog("Sparkle updater started")
        } catch {
            debugLog("Sparkle updater failed: \(error.localizedDescription)")
        }

        // 启动时只在「从未问过」时申请；已拒绝的不自动跳系统设置——
        // 配合开机自启，每次登录都被弹到「系统设置」体验极差，且用户无法关掉。
        // 已拒绝的用户在引导页 / 首页健康卡里点击时再跳（onboardingRequestMicrophone / openMicrophoneSettings）。
        requestMicrophonePermissionIfUndetermined()

        // 授权联网复核：退款/被找回页重置的设备，几天内自动退出激活（没网照常用）
        LicenseManager.shared.startRevalidation(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)

        // 自动学习调度（从成稿挖词、风格画像，两者现在都默认停用，见 AutoLearnScheduler.run）：启动后在后台低优先级跑一次，之后随投递节流触发
        AutoLearnScheduler.shared.debugLog = { [weak self] msg in self?.debugLog(msg) }
        AutoLearnScheduler.shared.scheduleLaunchRun()
        // 纠错学习：启动时整理一次候选（过期的、不像听错的清掉）
        HotWordsAutoLearner.shared.debugLog = { [weak self] msg in self?.debugLog(msg) }
        HotWordsAutoLearner.shared.pruneLearningCandidates()

        // Initialize components
        statusBar = StatusBarController(delegate: self)
        overlayWindow = OverlayWindow()
        overlayWindow.onCancelRecording = { [weak self] in self?.cancelRecording() }
        overlayWindow.onFinishRecording = { [weak self] in self?.stopRecordingAndProcess() }
        overlayWindow.onUndoCancel = { [weak self] in self?.redoCancelledRecording() }
        audioRecorder = AudioRecorder()
        audioRecorder.prepare()  // 只注册设备变更监听；引擎录音时才建，空闲不占系统音频设备
        cloudTranscriber = CloudASRTranscriber()
        cloudTranscriber.debugLog = { [weak self] message in
            self?.debugLog(message)
        }
        aiPolisher = AIPolisher()
        aiPolisher.polishLogAppNameProvider = { [weak self] in
            self?.currentFrontmostAppName() ?? "未知"
        }
        aiPolisher.debugLog = { [weak self] message in
            self?.debugLog(message)
        }
        textDelivery = TextDelivery()
        textDelivery.debugLog = { [weak self] message in
            self?.debugLog(message)
        }
        pipeline = VoicePolishPipeline(aiPolisher: aiPolisher, cloudTranscriber: cloudTranscriber)
        pipeline.debugLog = { [weak self] message in
            self?.debugLog(message)
        }
        pipeline.onStateChange = { [weak self] state in
            self?.handlePipelineState(state)
        }
        pipeline.onOutputLanguageApplied = { [weak self] language, command in
            // 口令触发的只提示前 3 次（教会用户口令生效了就退场；识别中胶囊的「→ EN」一直在）；默认语言不提示
            guard let command else { return }
            DispatchQueue.main.async {
                let key = "OutputLanguageHintShownCount"
                let shown = UserDefaults.standard.integer(forKey: key)
                guard shown < 3 else { return }
                UserDefaults.standard.set(shown + 1, forKey: key)
                self?.pendingOutputLanguageHint = "已按口令「\(command.matchedPhrase)」输出\(language.name)"
            }
        }
        pipeline.onPolishFailed = { [weak self] reason in
            DispatchQueue.main.async { self?.pendingPolishWarning = reason }
        }
        // 历史音频始终跟着文字一起保存（按同一保存时长过期删除）。纯本地、不上传。
        pipeline.audioSaver = { samples, id in
            AudioClipStore.defaultStore().save(samples: samples, id: id)
        }
        // 启动迁移历史加密，并在迁移后清理没有对应历史记录的音频文件。
        // 先挂观察者再启动迁移：迁移在后台读密钥，发现旧密钥丢失会广播这条通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyKeyWasRegenerated),
            name: HistoryCrypto.keyRegeneratedNotification,
            object: nil
        )
        migrateLocalHistoryEncryption()
        statusBar.setProcessingMode(processingMode)
        debugLog("Processing mode at launch: \(processingMode.debugName)")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // 首次运行展示引导。先于 updateAppReadiness() 呈现，
        // 这样辅助功能未授权时由引导负责索要权限，不会再额外弹独立的错误提示。
        if !VoicePolishConfig.shared.bool(forKey: "onboarding_completed") {
            debugLog("First run: presenting onboarding")
            showOnboarding()
        } else if !WhatsNewGuide.hasSeen, !UserDefaults.standard.bool(forKey: "WhatsNewGuideAutoShown_\(WhatsNewGuide.version)") {
            // 老用户升级到 3.0：第一次打开就把设置窗打开，新手势演示盖在上面，看完才进正式页面。
            // 只自动弹这一次：没看完就关掉的人，下次启动不再抢前台，从状态栏打开设置时仍会看到引导
            UserDefaults.standard.set(true, forKey: "WhatsNewGuideAutoShown_\(WhatsNewGuide.version)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.isOnboardingVisible else { return }
                self.debugLog("Presenting what's-new guide \(WhatsNewGuide.version)")
                self.showSettingsCenter()
            }
        }

        // 启动末尾主动调一次，注册 hotkey 并把状态栏置为 ready
        updateAppReadiness()
        startSupportPolling()

        // 没配 key 且未激活 → 自动进入/刷新免费试用（需 cloudTranscriber 已初始化）。
        maybeStartTrial()
    }

    /// 没配 key 且未激活 → 自动进入/刷新免费试用（owner 出 API 费）。断网静默，不阻塞启动。
    private func maybeStartTrial() {
        guard !cloudTranscriber.isConfigured(), !LicenseManager.shared.isActivated else { return }
        TrialManager.shared.refreshFromServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        hotkeyManager?.stop()
        mouseHoldToTalkManager?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 在访达 / 启动台再次打开时，系统会把 App 改回普通前台 App（Dock 图标又出来）；用户关了就再切回去
        debugLog("reopen: policy=\(NSApp.activationPolicy().rawValue) showDock=\(DockIcon.isShown)")
        DockIcon.apply()
        DispatchQueue.main.async { DockIcon.apply() }
        if !flag {
            showSettingsCenter()
        }
        return true
    }

    // MARK: - Recording Flow

    func toggleRecording() {
        if isProcessing { return }

        if isRecording {
            stopRecordingAndProcess()
        } else {
            guard canStartRecording(showFeedback: true) else { return }
            overlayWindow.recordingControls = .cancelAndFinish
            _ = startRecording()
        }
    }

    /// - Parameter feedback: 不能录（没配 Key / 试用到期 / 额度用完）时要不要弹提示胶囊。
    ///   问 AI 的长按、面板续聊传 false：默认开着的手势不该在空白处按住半秒就冒提示
    @discardableResult
    private func startRecording(feedback: Bool = true) -> Bool {
        guard !isRecording else { return false }
        guard canStartRecording(showFeedback: feedback) else { return false }
        // 反馈页用：记下这次是在哪个软件里录的（定位「某个软件里不好用」）
        if let name = NSWorkspace.shared.frontmostApplication?.localizedName, name != "Typefree" {
            lastRecordingTargetApp = name
        }
        if isAutoTermCorrectionLearningEnabled {
            HotWordsAutoLearner.shared.finalizePendingLearning(reason: "next_recording")
            HotWordsAutoLearner.shared.stopMonitoring()
        }
        isRecording = true
        clearHintQueue()
        debugLog("START recording")
        statusBar.setTitle("VP●")

        pendingOverlayHide?.cancel()   // 取消上一轮错误浮窗的延时隐藏，避免误杀本次录音浮窗
        if !voiceQuestionMode, !answerPanel.isPinned { answerPanel.hide() }
        // 问 AI 模式：蓝色光环，不显示语言标签；否则显示默认输出语言标签（防止忘了开着）
        overlayWindow.askGlow = voiceQuestionMode
        overlayWindow.languageTag = voiceQuestionMode ? nil : OutputLanguage.defaultLanguage()?.tag
        // 面板上续聊：录音状态画在面板底栏里（音浪 + 识别中），不弹底部胶囊
        // 长按问 AI：等判断出开口再弹胶囊（feedAskSpeechDetector），误触时什么都不冒出来
        if !voiceQuestionFollowUp, !askAwaitingSpeech { overlayWindow.show(state: .recording) }
        if askAwaitingSpeech { askRecordingStartedAt = Date() }

        let errorMsg = audioRecorder.startRecording { [weak self] level in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.voiceQuestionFollowUp { self.answerPanel.updateAudioLevel(level) } else { self.overlayWindow.updateAudioLevel(level) }
                if self.askAwaitingSpeech { self.feedAskSpeechDetector(level) }
            }
        }

        if let errorMsg = errorMsg {
            isRecording = false
            statusBar.setTitle("VP")
            showError("录音启动失败: \(errorMsg)")
            return false
        }
        // 工单 #1003：真正开始收音这一刻放开始音，用户听到就知道可以说了（也顺带缓解 #1008「说太快丢开头」）。
        // 结束和取消都响结束音。长按问 AI 在判出开口前可能是误触，两个都不出声。
        didPlayStartCue = !askAwaitingSpeech && CuePlayer.shared.isEnabled
        if didPlayStartCue { CuePlayer.shared.play(.start); debugLog("Cue: start（\(CuePlayer.shared.style.rawValue)）") }
        // 托管通道录音封顶（owner 出识别费，防开着不动烧钱）：试用 5 分钟；会员 9 分 50 秒——服务器单条上限 10 分钟，
        // 编码会多出零点几秒，留点余量免得整段被拒。到点正常停下并转写已录内容。
        let hostedRoute = HostedRoute.current(ownKeyConfigured: cloudTranscriber.isConfigured())
        if hostedRoute != .none {
            let cap: TimeInterval = hostedRoute == .member ? 590 : 300
            trialMaxRecordingTimer?.invalidate()
            trialMaxRecordingTimer = Timer.scheduledTimer(withTimeInterval: cap, repeats: false) { [weak self] _ in
                guard let self = self, self.isRecording else { return }
                self.debugLog("Hosted recording reached \(Int(cap))s cap — auto-stopping")
                self.stopRecordingAndProcess()
            }
        }
        setupStreamingIfEligible()
        return true
    }

    /// 边录边发：cloudOnly 模式下建流式会话，并每 3s 取样一次提交已说完的段落。
    /// omni（音频直喂大模型）与关闭开关时不启用，退化为松手后整段识别。
    private func setupStreamingIfEligible() {
        streamingSession = nil
        streamingTimer?.invalidate()
        streamingTimer = nil
        guard streamingEnabled, !processingMode.usesOmniDirectAudio else { return }

        // 提交/尾巴都走同一识别版本（不跟随失败回退，保持简单）；试用/自带 key 路由由 transcribe 内部处理。
        let version = cloudTranscriber.currentVersion()
        let session = StreamingTranscriptionSession(chunkTranscriber: { [weak self] samples, done in
            self?.cloudTranscriber.transcribe(samples: samples, version: version, completion: done)
        }, tailTranscriber: { [weak self] samples, done in
            self?.cloudTranscriber.transcribeAuto(samples: samples, version: version, completion: done)
        })
        session.debugLog = { [weak self] msg in self?.debugLog(msg) }
        streamingSession = session
        // 每 2s 取样一次：提交更勤 → 松手时未提交的尾巴更小 → 松手后等待更短。
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            DispatchQueue.global(qos: .utility).async {
                guard let session = self.streamingSession else { return }
                session.ingest(snapshot: self.audioRecorder.snapshotSamples())
            }
        }
    }

    private func stopRecordingAndProcess() {
        debugLog("STOP recording called, isRecording=\(isRecording), isProcessing=\(isProcessing)")
        guard isRecording else {
            debugLog("STOP ignored: not recording")
            return
        }
        if didPlayStartCue {
            didPlayStartCue = false
            CuePlayer.shared.play(.stop)
            debugLog("Cue: stop")
        }
        if voiceQuestionMode {
            stopRecordingAndAsk()
            return
        }
        trialMaxRecordingTimer?.invalidate()
        trialMaxRecordingTimer = nil
        isRecording = false
        hotkeyManager?.recordingDidLeaveActiveState()
        mouseHoldToTalkManager?.recordingDidLeaveActiveState()
        isProcessing = true
        statusBar.setTitle("VP⏳")
        let mode = processingMode

        // 收起流式取样定时器，取出本次会话（可能为 nil：omni / 开关关）。
        streamingTimer?.invalidate()
        streamingTimer = nil
        let session = streamingSession
        streamingSession = nil

        debugLog("Calling audioRecorder.stopRecording...")
        audioRecorder.stopRecording { [weak self] samples in
            guard let self = self else { return }
            self.debugLog("stopRecording callback: samples=\(samples?.count ?? -1)")
            guard let samples = samples, !samples.isEmpty else {
                self.debugLog("No audio samples!")
                DispatchQueue.main.async {
                    self.recordEmptyResult()
                }
                return
            }

            DispatchQueue.main.async {
                let generation = self.beginProcessing(samples: samples)
                self.processingSession = session
                DispatchQueue.global(qos: .userInitiated).async {
                    self.runProcessing(samples: samples, session: session, mode: mode, generation: generation)
                }
            }
        }
    }

    /// 松手后的识别 + 整理。generation 对不上（期间按 Esc 取消了 / 等太久放弃了）就不再往下走。
    private func runProcessing(samples: [Float], session: StreamingTranscriptionSession?, mode: ProcessingMode, generation: Int) {
            guard let session = session else {
                self.pipeline.process(samples: samples, mode: mode)  // omni / 未启用流式：原路径
                return
            }
            // 边录边发：松手时只剩尾巴要识别，先显示"识别中"，尾巴回来后走润色。
            DispatchQueue.main.async {
                self.handlePipelineState(.transcribing(message: mode.transcriptionOverlayMessage))
            }
            session.finish(finalSamples: samples) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    guard generation == self.processingGeneration else {
                        self.debugLog("Streaming result dropped (cancelled)")
                        return
                    }
                    switch result {
                    case .success(let rawText):
                        self.debugLog("Streaming finish success (\(rawText.count) chars)")
                        self.pipeline.processTranscribedText(rawText, samples: samples, mode: mode)
                    case .failure(let error as StreamingTranscriptionSession.PartialResultError):
                        // 尾巴两次没识别出来：前半段照常出字，并提醒后半段没出来（整段录音随这条记录进历史，可重试）
                        self.debugLog("Streaming tail failed: \(error.underlying) — delivering first part (\(error.text.count) chars)")
                        self.pendingPartialHint = Self.partialResultHint
                        self.pipeline.processTranscribedText(error.text, samples: samples, mode: mode)
                    case .failure(let error):
                        self.debugLog("Streaming finish failed: \(error) — fallback to batch")
                        self.pipeline.process(samples: samples, mode: mode)
                    }
                }
            }
    }

    /// 开始处理一段录音（主线程）：记下录音供 Esc 取消 / 放弃时留进历史，并开识别阶段的总等待封顶。
    private func beginProcessing(samples: [Float]) -> Int {
        processingGeneration += 1
        processingSamples = samples
        processingStartedAt = Date()
        startRecognitionWatchdog(audioSeconds: Double(samples.count) / 16000.0)
        return processingGeneration
    }

    /// 出字 / 报错 / 没内容 / 取消：这段录音处理完了
    private func endProcessing() {
        recognitionWatchdog?.cancel()
        recognitionWatchdog = nil
        processingSamples = nil
        processingSession = nil
    }

    /// 识别阶段最多等多久：正常一两秒就出字；网络卡住时到点直接放弃，不再陪着一轮轮重试干等。
    static func recognitionWaitCap(audioSeconds: Double) -> TimeInterval {
        min(240, 25 + audioSeconds * 0.4)
    }

    private func startRecognitionWatchdog(audioSeconds: Double) {
        recognitionWatchdog?.cancel()
        let cap = Self.recognitionWaitCap(audioSeconds: audioSeconds)
        let generation = processingGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.processingGeneration, let samples = self.processingSamples else { return }
            self.debugLog("Recognition gave up after \(Int(cap))s (audio \(String(format: "%.1f", audioSeconds))s)")
            self.pipeline.cancelCurrent()
            self.processingGeneration += 1
            // 边录边发已识别出前半段：先把这部分交给用户（照常整理、出字），并提醒后半段没出来
            if let partial = self.processingSession?.committedText, !partial.isEmpty {
                self.debugLog("Delivering first part (\(partial.count) chars) after giving up")
                self.processingSession = nil
                self.recognitionWatchdog = nil
                self.pendingPartialHint = Self.partialResultHint
                self.pipeline.processTranscribedText(partial, samples: samples, mode: self.processingMode)
                return
            }
            let kept = self.pipeline.preserveFailedRecording(samples: samples, startedAt: self.processingStartedAt)
            self.endProcessing()
            self.isProcessing = false
            self.statusBar.setTitle("VP")
            self.showError(kept ? "网络太慢，这段没识别出来 · 录音已存进历史，可点「···」→「重试」"
                                : "网络太慢，这段没识别出来，请再说一次")
        }
        recognitionWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cap, execute: work)
    }

    /// 识别 / 整理中按 Esc：放弃这次（晚到的结果不会再打字），和录音中取消一样给 5 秒「撤销」。
    private func cancelProcessing() {
        guard isProcessing, let samples = processingSamples else {
            debugLog("CANCEL processing ignored: nothing in progress")
            return
        }
        debugLog("CANCEL processing (Esc), elapsed \(String(format: "%.1f", Date().timeIntervalSince(processingStartedAt)))s")
        pipeline.cancelCurrent()
        processingGeneration += 1
        endProcessing()
        pendingPolishWarning = nil
        pendingOutputLanguageHint = nil
        pendingPartialHint = nil
        pendingOverlayHide?.cancel()
        pendingOverlayHide = nil
        isProcessing = false
        statusBar.setTitle("VP")
        overlayWindow.hide()
        cancelledSamples = samples
        cancelledWasAsk = false
        cancelledSamplesTimer?.invalidate()
        cancelledSamplesTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.cancelledSamples = nil
        }
        overlayWindow.showCancelledCapsule()
    }

    /// 「长按问 AI」松手：只识别，不润色不粘贴，把识别出的问题交给 AI，答案弹在按下点附近。
    private func stopRecordingAndAsk() {
        // 没判断出开口就松手：录了至少 1 秒且响到过过线值（离麦远时说话可能攒不够帧）才照常识别，
        // 识别不出话就悄悄收起，不弹「没听到问题」；太短或从头到尾没出声就是误触，静默丢弃
        let speechUnconfirmed = askAwaitingSpeech
        if speechUnconfirmed {
            let duration = askRecordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            guard duration >= 1.0, askSpeechDetector.peakReachedLine else {
                debugLog("ASK released before speech detected, \(String(format: "%.2f", duration))s (\(askSpeechDetector.summary)) → discard")
                discardAskRecording()
                return
            }
            debugLog("ASK released before speech detected (\(askSpeechDetector.summary)) → recognize anyway")
        }
        askRecordingStartedAt = nil
        askAwaitingSpeech = false
        voiceQuestionMode = false
        let followUp = voiceQuestionFollowUp
        voiceQuestionFollowUp = false
        answerPanel.setRecording(false)
        trialMaxRecordingTimer?.invalidate()
        trialMaxRecordingTimer = nil
        streamingTimer?.invalidate()
        streamingTimer = nil
        streamingSession = nil
        isRecording = false
        hotkeyManager?.recordingDidLeaveActiveState()
        mouseHoldToTalkManager?.recordingDidLeaveActiveState()
        isProcessing = true
        statusBar.setTitle("VP⏳")
        if followUp { answerPanel.setListening(.processing) } else { overlayWindow.show(state: .processing(message: "→ AI")) }
        audioRecorder.stopRecording { [weak self] samples in
            DispatchQueue.main.async {
                self?.askAI(with: samples, followUp: followUp, speechUnconfirmed: speechUnconfirmed)
            }
        }
    }

    /// 拿到录音后识别出问题、交给 AI，答案弹在面板里。松手提问和「撤销取消」共用这一段——
    /// 以前撤销走的是普通听写，取消的问题会被当成文字打进当前窗口（2026-09-23 发版前自查）。
    private func askAI(with samples: [Float]?, followUp: Bool, speechUnconfirmed: Bool) {
        let noSpeech: () -> Void = { [weak self] in
            guard let self else { return }
            self.finishAsk()
            if speechUnconfirmed { return }
            if followUp { self.answerPanel.setListening(.noSpeech) } else { self.overlayWindow.showHint("没听到问题", accent: .neutral) }
        }
        guard let samples, samples.count > 16000 / 2 else { noSpeech(); return }
        self.cloudTranscriber.transcribe(samples: samples) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let raw):
                    let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "。．.，,！!？?；;"))
                    guard !question.isEmpty else { noSpeech(); return }
                    self.debugLog("ASK question chars=\(question.count) followUp=\(followUp)")
                    self.overlayWindow.hide()
                    self.answerPanel.setListening(.idle)
                    let history = followUp ? self.answerPanel.history : []
                    if followUp, self.answerPanel.isVisible { self.answerPanel.appendQuestion(question) } else { self.answerPanel.startThread(question: question) }
                    let askStarted = Date()
                    let thread = self.answerPanel.threadID
                    self.aiPolisher.answer(question: question, history: history, onPartial: { [weak self] partial in
                        self?.answerPanel.updatePartial(partial)
                    }) { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.finishAsk()
                            switch result {
                            case .success(let answer):
                                self.debugLog("ASK answered chars=\(answer.count)")
                                self.answerPanel.finish(answer: answer)
                                self.aiPolisher.writeAskLog(question: question, answer: answer, thread: thread,
                                                            durationMs: Int(Date().timeIntervalSince(askStarted) * 1000))
                            case .failure(let err):
                                let reason = (err as? LocalizedError)?.errorDescription ?? "\(err)"
                                self.debugLog("ASK failed: \(reason)")
                                self.answerPanel.fail("回答失败：\(reason)")
                            }
                        }
                    }
                case .failure(let err):
                    // 没听到有效语音：安静地提示一次，不走红框 + 文字条的两段式报错
                    if case CloudASRTranscriber.TranscriptionError.noSpeech = err { noSpeech(); return }
                    self.finishAsk()
                    self.answerPanel.setListening(.idle)
                    let message = (err as? LocalizedError)?.errorDescription ?? "识别失败"
                    self.showError(message)
                }
            }
        }
    }

    // MARK: - 出字后的提示排队（2026-09-23 发版前自查）
    //
    // 出字后可能接连冒出好几条提示：「按英文输出」口令、「没粘上，按 ⌘V」、「润色失败」。
    // 提示胶囊同一时刻只有一条、新的顶掉旧的，以前「按 ⌘V」那条（最要紧：不按文字就丢了）
    // 零点几秒后就被别的提示盖掉。现在排队依次显示：每条至少停 2.5 秒，「按 ⌘V」插队到最前、至少停 4.5 秒。
    // 开始新的录音时清空队列，不让旧提示压在录音胶囊上。

    private struct QueuedHint {
        let text: String
        let accent: OverlayWindow.CapsuleAccent
        let urgent: Bool
    }
    private var hintQueue: [QueuedHint] = []
    private var hintBusyUntil = Date.distantPast
    private var hintPump: DispatchWorkItem?

    private func queueHint(_ text: String, accent: OverlayWindow.CapsuleAccent = .warning, urgent: Bool = false) {
        guard !isRecording else { return }   // 用户已经开始下一句：旧提示不再相关
        let hint = QueuedHint(text: text, accent: accent, urgent: urgent)
        if urgent, let i = hintQueue.firstIndex(where: { !$0.urgent }) {
            hintQueue.insert(hint, at: i)
        } else {
            hintQueue.append(hint)
        }
        pumpHints()
    }

    private func pumpHints() {
        hintPump?.cancel()
        hintPump = nil
        guard !hintQueue.isEmpty else { return }
        if isRecording { clearHintQueue(); return }
        let wait = hintBusyUntil.timeIntervalSinceNow
        if wait > 0 {
            let work = DispatchWorkItem { [weak self] in self?.pumpHints() }
            hintPump = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            return
        }
        let hint = hintQueue.removeFirst()
        overlayWindow.showHint(hint.text, accent: hint.accent)
        hintBusyUntil = Date().addingTimeInterval(hint.urgent ? 4.5 : 2.5)
        pumpHints()
    }

    private func clearHintQueue() {
        hintQueue.removeAll()
        hintPump?.cancel()
        hintPump = nil
        hintBusyUntil = .distantPast
    }

    private func finishAsk() {
        isProcessing = false
        statusBar.setTitle("VP")
        if overlayWindow.capsuleCenterOnScreen != nil { overlayWindow.hide() }
    }

    /// 鼠标长按问 AI 的开口判定：听到说话才真正进入提问（收起旧回答、接管鼠标）
    private func feedAskSpeechDetector(_ level: Float) {
        guard isRecording, voiceQuestionMode else { askAwaitingSpeech = false; return }
        guard askSpeechDetector.feed(level) else { return }
        askAwaitingSpeech = false
        debugLog("ASK speech detected (level \(String(format: "%.2f", level)); \(askSpeechDetector.summary))")
        if !answerPanel.isPinned { answerPanel.hide() }
        // 开口确认了才弹胶囊；先于接管按键，拖开取消 / 下拉锁定要用胶囊位置
        overlayWindow.show(state: .recording)
        mouseHoldToTalkManager?.askSpeechDetected()
    }

    /// 鼠标长按问 AI 在判断出开口前被拖动（是在 App 里选字）：当作没发生过——
    /// 收起胶囊、丢掉录音，不提示「没听到问题」、不给撤销、不调识别
    private func discardAskRecording() {
        guard isRecording, voiceQuestionMode else { return }
        debugLog("ASK discarded before speech (\(askSpeechDetector.summary))")
        askRecordingStartedAt = nil
        askAwaitingSpeech = false
        voiceQuestionMode = false
        voiceQuestionFollowUp = false
        trialMaxRecordingTimer?.invalidate()
        trialMaxRecordingTimer = nil
        streamingTimer?.invalidate()
        streamingTimer = nil
        streamingSession = nil
        pendingOverlayHide?.cancel()
        pendingOverlayHide = nil
        isRecording = false
        hotkeyManager?.recordingDidLeaveActiveState()
        mouseHoldToTalkManager?.recordingDidLeaveActiveState()
        statusBar.setTitle("VP")
        overlayWindow.hide()
        audioRecorder.stopRecording { _ in }
    }

    private func cancelRecording() {
        debugLog("CANCEL recording called, isRecording=\(isRecording), isProcessing=\(isProcessing)")
        // 长按问 AI 还没判出开口（用户什么都还没看到，也可能只是误触）：静悄悄丢掉，不冒「已取消 · 撤销」
        if isRecording, voiceQuestionMode, askAwaitingSpeech {
            discardAskRecording()
            return
        }
        let wasAsk = voiceQuestionMode
        askAwaitingSpeech = false
        voiceQuestionMode = false
        let wasFollowUp = voiceQuestionFollowUp
        voiceQuestionFollowUp = false
        answerPanel.setRecording(false)
        guard isRecording else {
            debugLog("CANCEL ignored: not recording")
            return
        }
        // 取消也响结束音（Ray 2026-09-23：按下有声、取消没声不对称）；只跟在开始音后面放
        if didPlayStartCue {
            didPlayStartCue = false
            CuePlayer.shared.play(.stop)
            debugLog("Cue: stop（取消）")
        }

        trialMaxRecordingTimer?.invalidate()
        trialMaxRecordingTimer = nil
        streamingTimer?.invalidate()
        streamingTimer = nil
        streamingSession = nil
        pendingOverlayHide?.cancel()
        pendingOverlayHide = nil
        isRecording = false
        hotkeyManager?.recordingDidLeaveActiveState()
        mouseHoldToTalkManager?.recordingDidLeaveActiveState()
        isProcessing = false
        statusBar.setTitle("VP")
        overlayWindow.hide()
        // 误点保护：不直接丢录音，暂存并给一个「撤销」窗口；窗口过后自动清掉。
        audioRecorder.stopRecording { [weak self] samples in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard let samples = samples, !samples.isEmpty else { return }   // 太短没采到内容：静默作罢
                // 面板续聊取消：不给「撤销」（撤销走的是润色粘贴，不是提问），面板底栏轻提示一下
                if wasFollowUp { self.answerPanel.setListening(.cancelled); return }
                self.cancelledSamples = samples
                self.cancelledWasAsk = wasAsk
                self.cancelledSamplesTimer?.invalidate()
                self.cancelledSamplesTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                    self?.cancelledSamples = nil
                }
                self.overlayWindow.showCancelledCapsule()
            }
        }
    }

    /// 误点了叉号 → 点「撤销」：用刚才暂存的录音重新识别，照常润色输出。
    private func redoCancelledRecording() {
        guard let samples = cancelledSamples, !isRecording, !isProcessing else { return }
        cancelledSamples = nil
        cancelledSamplesTimer?.invalidate()
        cancelledSamplesTimer = nil
        let wasAsk = cancelledWasAsk
        cancelledWasAsk = false
        debugLog("UNDO cancel: re-processing \(samples.count) samples as \(wasAsk ? "ask" : "dictation")")
        isProcessing = true
        statusBar.setTitle("VP⏳")
        if wasAsk {
            // 取消的是问 AI：撤销 = 重新把这个问题交给 AI（答案仍弹在当初按下的位置附近）
            overlayWindow.show(state: .processing(message: "→ AI"))
            askAI(with: samples, followUp: false, speechUnconfirmed: false)
        } else {
            _ = beginProcessing(samples: samples)
            pipeline.process(samples: samples, mode: processingMode)
        }
    }

    /// 启动时把旧的明文历史文字/音频收敛成密文；失败时保留原文件，下次启动再试。
    private func migrateLocalHistoryEncryption() {
        DispatchQueue.global(qos: .utility).async {
            if let logFile = AIPolisher.historyLogFileURL() {
                _ = HistoryCrypto.migrateLogFile(at: logFile)
            }
            AudioClipStore.defaultStore().migrateAll()
            self.cleanupOrphanAudio()
        }
    }

    /// 启动时清理孤儿音频：删掉 audio/ 下没有对应历史记录的文件（防 ID 漂移残留）。
    private func cleanupOrphanAudio() {
        DispatchQueue.global(qos: .utility).async {
            guard let logFile = AIPolisher.historyLogFileURL() else { return }
            // 读文件 → 删孤儿音频 放同一把锁里：否则这期间刚追加的记录，其音频会被当孤儿删掉。
            HistoryFileLock.withLock {
                guard let content = try? String(contentsOf: logFile, encoding: .utf8) else { return }
                let enc = HistoryCrypto.defaultEncryptor()
                var keep = Set<String>()
                for line in content.split(separator: "\n") where !line.isEmpty {
                    let rawLine = String(line)
                    if HistoryCrypto.isEncryptedLine(rawLine),
                       HistoryCrypto.decodeLine(rawLine, enc: enc) == nil {
                        return
                    }
                    guard let log = HistoryCrypto.decodeLine(rawLine, enc: enc),
                          let audio = log.audioFile else { continue }
                    keep.insert(audio)
                }
                AudioClipStore.defaultStore().pruneOrphans(keeping: keep)
            }
        }
    }

    /// 历史加密密钥丢失（钥匙串被重置等）且旧记录仍在：告知用户一次，别让历史「悄悄消失」。
    @objc private func historyKeyWasRegenerated() {
        let alert = NSAlert()
        alert.messageText = "历史记录的加密密钥已丢失"
        alert.informativeText = "钥匙串里找不到之前用来加密历史记录的密钥（通常是钥匙串被重置或迁移过）。\n\n之前的历史记录无法再读取；从现在起的新记录会用新密钥正常保存。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    /// 录音太短没采到音频 / 识别结果为空：不报红框、不粘贴，安静收起浮窗，
    /// 只在历史里留一条「无内容」记录（asr/output 均为空，复制不会带出占位字）。
    private func recordEmptyResult() {
        pendingOverlayHide?.cancel()
        pendingOverlayHide = nil
        isProcessing = false
        statusBar.setTitle("VP")
        overlayWindow.hide()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.aiPolisher.writePolishLog(asr: "", output: "", durationMs: 0)
        }
    }

    private func showError(_ message: String) {
        pendingOverlayHide?.cancel()
        overlayWindow.show(state: .error(message: message))
        // 失败提示按文字长短停留 4~12 秒——长录音失败的提示要让用户看清、知道原因。
        let seconds = min(12.0, max(4.0, Double(message.count) * 0.2))
        // 红色胶囊本身不画文字，只闪 0.7 秒表示"失败了"，随后换成可读的文字条说明原因。
        // 之前只有无字红框，用户根本不知道是没开通服务、断网还是别的（用户反馈"红框没字"）。
        // 用 pendingOverlayHide 挂这个切换：期间若又开始录音会被取消，不会误把录音胶囊收掉。
        let work = DispatchWorkItem { [weak self] in
            self?.overlayWindow.showErrorHint(message, seconds: seconds)
        }
        pendingOverlayHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func doneMessage(for text: String, deliveryResult: TextDelivery.DeliveryResult) -> String {
        switch deliveryResult {
        case .pasted:
            return text
        case .copiedOnlyNeedsAccessibility:
            return text + "\n(已复制到剪贴板；授予辅助功能权限后可自动粘贴)"
        case .pastedKeptClipboard:
            return text
        }
    }

    /// 建立标准主菜单（App 菜单 + 编辑菜单）。
    /// 关键作用：编辑菜单里「剪切/拷贝/粘贴/全选/撤销」带标准快捷键，
    /// macOS 正是靠这些菜单项把 Cmd+X/C/V/A/Z 分发给当前输入框。
    /// 之前 App 没有主菜单，所以这些快捷键全失效，只能右键粘贴。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App 菜单（隐藏 / 退出）
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "隐藏 Typefree", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Typefree", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 编辑菜单（让 Cmd+X/C/V/A/Z 生效）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    private func requestMicrophonePermissionIfUndetermined() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    /// 用户主动点击（引导页「开启麦克风」）：未决→弹系统授权框；已拒绝→打开系统设置。
    private func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .denied, .restricted:
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        default:
            break
        }
    }

    private func canStartRecording(showFeedback: Bool) -> Bool {
        if isProcessing { return false }

        if processingMode.usesCloudTranscription && !cloudTranscriber.isConfigured() {
            // 自带 Key 用户（选的服务没 Key / 钥匙串读不到）：说清楚原因，别提示「试用已结束」误导（工单 #1030）
            let ownKeyHint = cloudTranscriber.ownKeyIssue().map(CloudASRTranscriber.hint(for:))
            if let ownKeyHint { debugLog("Cloud ASR own key issue: \(ownKeyHint)") }
            if !LicenseManager.shared.isActivated {
                if TrialManager.shared.isInTrial {
                    // 7 天总额用完 = 试用结束（服务器会 429），别再上传音频白跑一趟
                    if TrialManager.shared.isTotalExhausted {
                        TrialManager.shared.refreshFromServer()   // 服务器可能调高/重置过额度，对一次账，下次按就能用
                        if showFeedback {
                            overlayWindow.showHint("试用额度已用完（7 天共 \(TrialManager.formatChars(TrialManager.shared.totalLimit)) 字）· 开通会员，或填自己的 Key 不限量")
                        }
                        return false
                    }
                    // 试用中：当日额度（缓存值，服务器才是权威）没满就放行；放行后不再走下面的免费额度检查。
                    if TrialManager.shared.usedToday >= TrialManager.shared.dailyLimit {
                        TrialManager.shared.refreshFromServer()   // 缓存可能旧了，顺手对一次账
                        if showFeedback {
                            overlayWindow.showHint("今日试用额度已用完（剩 \(TrialManager.shared.daysLeft) 天）· 开通会员或填自己的 Key 不限量")
                        }
                        return false
                    }
                    return true
                }
                if TrialManager.shared.trialExpired {
                    if showFeedback {
                        overlayWindow.showHint(ownKeyHint ?? "试用已结束 · 开通会员，或在「设置 → 模型」填自己的 Key")
                    }
                    return false
                }
                if !TrialManager.shared.isTrialAvailable {
                    // 自己编译的开源版没有试用通道（试用地址不进公开仓库）：直接引导填 Key。
                    if showFeedback {
                        overlayWindow.showHint(ownKeyHint ?? "请先在「设置 → 模型」里填入 API Key")
                    }
                    return false
                }
                // 试用还没拉到（首启刷新中 / 断网）→ 触发一次刷新并提示稍候。
                TrialManager.shared.refreshFromServer()
                if showFeedback {
                    overlayWindow.showHint("正在准备免费试用，请稍候…")
                }
                return false
            }
            // 已激活：年付会员走托管通道；老买断/赠送码需要自己的 Key
            let license = LicenseManager.shared
            if license.isMember && TrialManager.shared.isTrialAvailable {
                if license.isMemberExpired() {
                    if showFeedback {
                        overlayWindow.showHint("会员已到期 · 续费，或在「设置 → 模型」填自己的 Key")
                    }
                    return false
                }
                if license.hasActiveMembership() { return true }
                // 会员有效但手里还没有可用令牌（刚转成会员 / 很久没联网）→ 立刻复核一次；联不上就说清楚是网络
                license.revalidateNow { [weak self] ok in
                    guard let self, !ok, showFeedback else { return }
                    self.overlayWindow.showHint("无法连接激活服务，请检查网络后再试")
                }
                if showFeedback {
                    overlayWindow.showHint("正在验证会员状态，请稍候…")
                }
                return false
            }
            if showFeedback {
                overlayWindow.showHint(ownKeyHint ?? "请先在「设置 → 模型」里填入 API key")
                debugLog("Cloud ASR unavailable: \(cloudTranscriber.missingConfigurationHint())")
            }
            return false
        }

        // 2026-09-14 起自带 Key 不再限每周字数（开源后限制形同虚设，且自带 Key 不花我们的钱）。
        return true
    }

    private func updateAppReadiness() {
        updateAccessibilityDependentFeatures()

        if !isRecording && !isProcessing {
            statusBar.setTitle("VP")
        }
    }

    private func updateAccessibilityDependentFeatures() {
        guard let textDelivery = textDelivery else { return }

        let hasAccessibility = textDelivery.hasAccessibilityPermission()
        debugLog("Accessibility trusted=\(hasAccessibility)")

        guard hasAccessibility else {
            hotkeyManager?.stop()
            hotkeyManager = nil
            mouseHoldToTalkManager?.stop()
            mouseHoldToTalkManager = nil
            startAccessibilityWatcher()
            if !isRecording && !isProcessing {
                statusBar.setTitle("VP!")
            }
            // 引导窗口正在前台时，由引导负责索要辅助功能权限，避免重复弹窗/提示
            if isOnboardingVisible {
                debugLog("Accessibility not granted yet; onboarding owns the prompt")
                return
            }
            if !didPromptForAccessibility {
                _ = textDelivery.hasAccessibilityPermission(promptIfNeeded: true)
                didPromptForAccessibility = true
            }
            if !didReportMissingAccessibility {
                debugLog("Accessibility not granted yet; skipping global hotkey listener")
                showError("请授予辅助功能权限以启用快捷键")
                didReportMissingAccessibility = true
            }
            return
        }

        didPromptForAccessibility = false
        didReportMissingAccessibility = false
        ensureHotkeyManager()
    }

    /// 辅助功能未授权时每 2 秒检测一次；用户在系统设置里一打开就立刻接管快捷键，
    /// 不用重启 App（事件监听是授权后新建的，能直接生效）。
    private func startAccessibilityWatcher() {
        guard axPollTimer == nil else { return }
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self,
                  self.textDelivery?.hasAccessibilityPermission() == true else { return }
            self.axPollTimer?.invalidate()
            self.axPollTimer = nil
            self.debugLog("Accessibility granted while running; enabling hotkey without restart")
            self.updateAppReadiness()
            NotificationCenter.default.post(name: .voicePolishAccessibilityGranted, object: nil)
            // 引导窗口在场时由引导自己反馈，不重复弹提示
            if !self.isOnboardingVisible {
                self.overlayWindow.showHint("辅助功能已开启，现在可以用快捷键录音了", accent: .success)
            }
        }
    }

    private func ensureHotkeyManager() {
        guard hotkeyManager == nil else { return }

        debugLog("Model ready, starting hotkey listener")
        hotkeyManager = HotkeyManager(
            onStart: { [weak self] in
                guard let self else { return false }
                // 键盘触发一律从第一帧就显示大胶囊（叉号 + 对勾），单击、长按统一，中途不变形（Ray 2026-09-11 拍板）。
                // 长按时松手照常结束、Esc 照常取消；鼠标长按说话仍是小胶囊，不受影响。
                self.overlayWindow.recordingControls = .cancelAndFinish
                return self.startRecording()
            },
            onStop: { [weak self] in self?.stopRecordingAndProcess() },
            isRecording: { [weak self] in self?.isRecording == true }
        )
        hotkeyManager.debugLog = { [weak self] msg in
            self?.debugLog("HK: \(msg)")
        }
        // 键盘触发的胶囊不再按单击/长按切换大小，这里不用改按钮
        hotkeyManager.onGestureClassified = { _ in }
        hotkeyManager.onCancel = { [weak self] in self?.cancelRecording() }
        ensureMouseHoldToTalkManager()
    }

    /// 鼠标长按说话：监听器常驻，开关状态在每次按下时读取，设置里切换立即生效、无需重建
    private func ensureMouseHoldToTalkManager() {
        guard mouseHoldToTalkManager == nil else { return }
        let manager = MouseHoldToTalkManager(
            onStart: { [weak self] in
                guard let self else { return false }
                self.overlayWindow.recordingControls = .hidden   // 松手即完成、拖开即取消，不需要按钮
                guard self.startRecording() else { return false }
                let hintKey = "MouseHoldCapsuleLockHintShownCount"
                let shown = UserDefaults.standard.integer(forKey: hintKey)
                if shown < 3 {
                    UserDefaults.standard.set(shown + 1, forKey: hintKey)
                    self.overlayWindow.showRecordingCaption("移近锁定", seconds: 1.8)
                }
                return true
            },
            onStop: { [weak self] in self?.stopRecordingAndProcess() },
            isRecording: { [weak self] in self?.isRecording == true }
        )
        manager.debugLog = { [weak self] msg in
            self?.debugLog("MH: \(msg)")
        }
        manager.onCancel = { [weak self] in self?.cancelRecording() }
        manager.onLock = { [weak self] in
            self?.overlayWindow.setRecordingLocked(true)
        }
        overlayWindow.onLockedDragStart = { [weak manager] point in
            manager?.beginLockedCapsuleDrag(at: point) ?? false
        }
        overlayWindow.onLockedDragUpdate = { [weak manager] point in
            manager?.updateLockedCapsuleDrag(at: point)
        }
        overlayWindow.onLockedDragEnd = { [weak manager] point in
            manager?.endLockedCapsuleDrag(at: point)
        }
        AnswerPanel.log = { [weak self] in self?.debugLog($0) }
        answerPanel.isAskPending = { [weak self] in self?.askAwaitingSpeech == true }
        answerPanel.onFollowUpStart = { [weak self] in
            guard let self, !self.isRecording, !self.isProcessing else { return false }
            self.voiceQuestionMode = true
            self.voiceQuestionFollowUp = true
            self.overlayWindow.recordingControls = .hidden
            guard self.startRecording(feedback: false) else { self.voiceQuestionMode = false; self.voiceQuestionFollowUp = false; return false }
            self.answerPanel.setRecording(true)
            return true
        }
        answerPanel.onFollowUpEnd = { [weak self] cancelled in
            guard let self else { return }
            self.answerPanel.setRecording(false)
            if cancelled { self.cancelRecording() } else { self.stopRecordingAndProcess() }
        }
        manager.onStartAsk = { [weak self] in
            guard let self else { return false }
            guard MouseHoldToTalkSettings.isAskEnabled else { return false }
            // 旧回答面板等用户开口再收起（feedAskSpeechDetector）：误触时什么都不动
            self.voiceQuestionFollowUp = false
            self.voiceQuestionMode = true
            self.voiceQuestionAnchor = NSEvent.mouseLocation
            self.askAwaitingSpeech = true
            self.askSpeechDetector = AskSpeechDetector()
            self.overlayWindow.recordingControls = .hidden
            guard self.startRecording(feedback: false) else { self.voiceQuestionMode = false; self.askAwaitingSpeech = false; return false }
            return true
        }
        manager.onAbortAsk = { [weak self] in self?.discardAskRecording() }
        // 新手势演示盖在设置窗上时，「试一试」输入框要能按住说话：只对那个窗口放行
        manager.guideWindowNumber = { SettingsWindowController.shared?.guideWindowNumber }
        // 设置窗里的输入框（工单对话框等）也能按住说话（Ray 2026-09-18：工单里没法长按输入）
        manager.dictationWindowNumber = { SettingsWindowController.shared?.dictationWindowNumber }
        manager.capsuleCenterProvider = { [weak self] in self?.overlayWindow.capsuleCenterOnScreen }
        manager.capsuleFrameProvider = { [weak self] in self?.overlayWindow.capsuleFrameOnScreen }
        manager.onHoldGestureUpdate = { [weak self] gesture in
            self?.overlayWindow.setCancelArmed(gesture.armed)
        }
        manager.onHoldGestureEnded = { [weak self] _ in
            self?.overlayWindow.endCancelGesture()
            self?.overlayWindow.setRecordingLocked(false)
        }
        mouseHoldToTalkManager = manager
        debugLog("MH: listening=\(manager.isListening) enabled=\(MouseHoldToTalkSettings.isEnabled)")
    }

    func openAccessibilitySettings() {
        textDelivery?.openAccessibilitySettings()
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 反馈对话（SettingsWindowDelegate）

    func recentTargetAppName() -> String? { lastRecordingTargetApp }

    /// 最近 120 行调试日志（不含用户说的内容：日志里只有字数、耗时、软件名这类元信息）
    func debugLogTail() -> String {
        let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VoicePolish.log")
        guard let data = try? Data(contentsOf: logFile), let text = String(data: data, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let tail = lines.suffix(120).joined(separator: "\n")
        return String(tail.suffix(SupportChatService.maxLogChars))
    }

    /// 开始过对话的设备每 5 分钟拉一次新回复；没开始过的一次网络请求都不发
    private func startSupportPolling() {
        supportPollTimer?.invalidate()
        let timer = Timer(timeInterval: SupportChatService.pollInterval, repeats: true) { _ in
            guard SupportChatService.shared.hasThread else { return }
            SupportChatService.shared.sync()
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        supportPollTimer = timer
        if SupportChatService.shared.hasThread {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { SupportChatService.shared.sync() }
        }
    }

    func showSettingsCenter() {
        SettingsWindowController.show(delegate: self)
    }

    /// 打开设置并直接跳到「模型」标签页（供引导第 2 步使用）
    func showModelSettings() {
        SettingsWindowController.show(delegate: self, initialPage: .model)
    }

    /// 菜单栏「个人词库…」直达词库页（工单 #17）
    func showVocabularySettings() {
        SettingsWindowController.show(delegate: self, initialPage: .vocabulary)
    }

    // MARK: - First-run Onboarding

    private var onboardingController: OnboardingWindowController?

    /// 供引导窗口轮询读取的状态
    func onboardingHasAccessibility() -> Bool {
        textDelivery?.hasAccessibilityPermission() ?? false
    }

    func onboardingIsAPIConfigured() -> Bool {
        cloudTranscriber?.isConfigured() ?? false
    }

    func onboardingHasMicrophone() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func onboardingMicrophoneDenied() -> Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        return s == .denied || s == .restricted
    }

    /// 引导里点"开启麦克风"：未决→弹系统授权框；已拒绝→打开系统设置。复用启动时同一逻辑。
    func onboardingRequestMicrophone() {
        requestMicrophonePermission()
    }

    func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(appDelegate: self)
        }
        onboardingController?.present()
    }

    func markOnboardingCompleted() {
        VoicePolishConfig.shared.save(bool: true, forKey: "onboarding_completed")
    }

    /// 引导窗口是否正在前台显示（用于避免重复弹辅助功能错误提示）
    private var isOnboardingVisible: Bool {
        onboardingController?.isVisible ?? false
    }


    // MARK: - Manual Correction & Learning Feedback

    /// 菜单栏「复制最后一句」：把上一次出的文字重新放回剪贴板。
    /// 工单 #1016 的兜底——焦点判不出来（微信、网页这类读不到结构的 App 我们一律不下结论）、
    /// 或者用户没留意那条胶囊提示时，随时能把刚才说的话捞回来，不用重说一遍。
    func copyLastDeliveredText() {
        guard let lastText = lastDeliveredText, !lastText.isEmpty else {
            showError("还没有可复制的内容")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastText, forType: .string)
        debugLog("菜单栏：复制最后一句 chars=\(lastText.count)")
        overlayWindow.showHint("已复制最后一句 · 按 ⌘V 粘贴", accent: .success)
    }

    func showManualCorrection() {
        guard let lastText = lastDeliveredText, !lastText.isEmpty else {
            showError("没有可纠正的内容")
            return
        }

        let alert = NSAlert()
        alert.messageText = "纠正上次结果"
        let displayText = lastText.count > 80 ? String(lastText.prefix(80)) + "..." : lastText
        alert.informativeText = "Typefree 输出了：\n\(displayText)\n\n请在下方修改为正确的文字："
        alert.addButton(withTitle: "学习")
        alert.addButton(withTitle: "取消")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 396, height: 80))
        textView.string = lastText
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

        let corrected = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty, corrected != lastText else { return }

        let learner = HotWordsAutoLearner.shared
        learner.debugLog = { [weak self] msg in self?.debugLog(msg) }
        let learned = learner.learnFromManualCorrection(original: lastText, corrected: corrected)
        if learned.isEmpty {
            // 只有改对的是专有名词（人名、品牌、术语）才进词库；常用词识别本来就认得，不用加
            overlayWindow.showHint("没有需要加进词库的新词", accent: .neutral)
        } else {
            showLearningFeedback(learned)
        }
    }

    private var lastLearnedDescriptions: [String] = []
    private var lastLearningSuggestionDescriptions: [String] = []

    private func showLearningFeedback(_ descriptions: [String]) {
        debugLog("Learned corrections: count=\(descriptions.count)")
        lastLearnedDescriptions = descriptions

        overlayWindow.onUndoLearn = { [weak self] in
            guard let self = self, !self.lastLearnedDescriptions.isEmpty else { return }
            let toUndo = self.lastLearnedDescriptions
            self.lastLearnedDescriptions = []
            let learner = HotWordsAutoLearner.shared
            learner.debugLog = { [weak self] msg in self?.debugLog(msg) }
            learner.undoLearnedWords(toUndo)
            self.debugLog("User undid learned words: count=\(toUndo.count)")
        }

        let displayText = descriptions.joined(separator: "、")
        overlayWindow.show(state: .learned(description: displayText))
    }

    private func showLearningSuggestion(_ descriptions: [String]) {
        debugLog("Learning suggestions: count=\(descriptions.count)")
        lastLearningSuggestionDescriptions = descriptions

        overlayWindow.onAcceptLearnSuggestion = { [weak self] in
            guard let self = self, !self.lastLearningSuggestionDescriptions.isEmpty else { return }
            let toLearn = self.lastLearningSuggestionDescriptions
            self.lastLearningSuggestionDescriptions = []

            let learner = HotWordsAutoLearner.shared
            learner.debugLog = { [weak self] msg in self?.debugLog(msg) }
            let learned = learner.confirmPendingCorrections(toLearn)
            if learned.isEmpty {
                self.debugLog("Learning suggestions accepted but nothing new was added: count=\(toLearn.count)")
            } else {
                self.showLearningFeedback(learned)
            }
        }

        overlayWindow.onDismissLearnSuggestion = { [weak self] in
            self?.debugLog("Learning suggestions deferred: count=\(descriptions.count)")
            self?.lastLearningSuggestionDescriptions = []
        }

        let displayText = descriptions.joined(separator: "、")
        overlayWindow.show(state: .learnSuggestion(description: displayText))
    }

    func currentProcessingMode() -> ProcessingMode {
        processingMode
    }

    func setProcessingMode(_ mode: ProcessingMode) {
        guard processingMode != mode else { return }
        processingMode = mode
        if let group = UserDefaults(suiteName: ProcessingMode.appGroupSuiteName) {
            group.set(mode.rawValue, forKey: ProcessingMode.userDefaultsKey)
        }
        UserDefaults.standard.set(mode.rawValue, forKey: ProcessingMode.userDefaultsKey)
        statusBar?.setProcessingMode(mode)
        debugLog("Processing mode changed to \(mode.debugName)")
        updateAppReadiness()
    }

    // MARK: - Pipeline State Handling

    private func handlePipelineState(_ state: VoicePolishPipeline.State) {
        DispatchQueue.main.async {
            // 已取消 / 已放弃（刚好和结果擦肩而过）：不再显示、不打字
            guard self.isProcessing else {
                self.debugLog("Pipeline state ignored: not processing")
                return
            }
            switch state {
            case .transcribing(let message):
                self.overlayWindow.show(state: .processing(message: message))

            case .polishing(let message):
                // 识别完成：总等待封顶只管识别，整理慢了会退回原文（润色失败照常出字）
                self.recognitionWatchdog?.cancel()
                self.recognitionWatchdog = nil
                self.overlayWindow.show(state: .processing(message: message))

            case .done(let text):
                self.debugLog("Pipeline done received on main chars=\(text.count)")
                self.endProcessing()
                self.isProcessing = false
                self.statusBar.setTitle("VP")
                let frontmostAppName = self.currentFrontmostAppName()
                let deliveredText = TextDelivery.adjustedTextForDelivery(text, frontmostAppName: frontmostAppName)
                if deliveredText != text {
                    self.debugLog("Chat punctuation: removed trailing full stop")
                }
                self.lastDeliveredText = deliveredText

                if self.isAutoTermCorrectionLearningEnabled {
                    HotWordsAutoLearner.shared.prepareForDelivery()
                }
                self.overlayWindow.completeProgressOnly {
                    self.overlayWindow.hide()
                }
                let result = self.textDelivery.deliver(text: deliveredText, onNotLanded: { [weak self] in
                    // 工单 #1016 第二轮：网页正文上说完话，粘完核实焦点没进输入框 → 文字多半没粘上，剪贴板留着
                    self?.debugLog("TextDelivery: 网页里多半没粘上，提示用户 ⌘V")
                    self?.queueHint("文字可能没粘上 · 已复制，按 ⌘V 粘贴", urgent: true)
                })
                if let hint = self.pendingOutputLanguageHint {
                    self.pendingOutputLanguageHint = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        self?.queueHint(hint, accent: .success)
                    }
                }
                switch result {
                case .pasted:
                    self.debugLog("TextDelivery: deliver returned pasted")
                case .copiedOnlyNeedsAccessibility:
                    self.debugLog("TextDelivery: deliver returned copiedOnlyNeedsAccessibility")
                case .pastedKeptClipboard:
                    // 工单 #1016：焦点不在输入框时，文字以前会凭空消失（粘不进去 + 剪贴板被还原）。
                    // 现在剪贴板留着这段文字，明确告诉用户按 ⌘V。走提示队列插队显示，不会被口令 / 润色失败提示盖掉。
                    self.debugLog("TextDelivery: deliver returned pastedKeptClipboard（焦点不在输入框）")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        self?.queueHint("刚才的位置不能输入文字 · 已复制，按 ⌘V 粘贴", urgent: true)
                    }
                }
                // quotaCharCount 只剩统计用途（每周字数限制已在 2026-09-14 取消）：仍按「未赞助 + 自带 Key」口径记，
                // 保持 input_stats.json 老字段兼容。
                let usedTrialProxy = self.processingMode.usesCloudTranscription
                    && !self.cloudTranscriber.isConfigured()
                    && TrialManager.shared.isInTrial
                let countsTowardQuota = !LicenseManager.shared.isActivated && !usedTrialProxy
                InputStats.shared.record(charCount: deliveredText.count,
                                         countsTowardFreeQuota: countsTowardQuota)
                AutoLearnScheduler.shared.noteRecordDelivered()

                if let hint = self.pendingPartialHint {
                    self.pendingPartialHint = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.queueHint(hint) }
                }

                // 润色失败（额度用尽/欠费等）：文字已照常输出，但明确提醒一次，别让额度耗尽被静默跳过。
                if let warning = self.pendingPolishWarning {
                    self.pendingPolishWarning = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let tip = warning.contains("额度") && !LicenseManager.shared.hasActiveMembership() ? " · 开通会员或填自己的 Key 不限量" : ""
                        self.queueHint("已输出未润色文字（润色失败：\(warning)）\(tip)")
                    }
                }

                if self.isAutoTermCorrectionLearningEnabled && result == .pasted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let learner = HotWordsAutoLearner.shared
                        learner.debugLog = { [weak self] msg in self?.debugLog(msg) }
                        learner.onLearned = { [weak self] descriptions in
                            self?.showLearningFeedback(descriptions)
                        }
                        learner.onLearningCandidate = { [weak self] descriptions in
                            self?.showLearningSuggestion(descriptions)
                        }
                        learner.startMonitoring(deliveredText: deliveredText)
                    }
                }

            case .error(let message):
                self.pendingPartialHint = nil
                self.endProcessing()
                self.isProcessing = false
                self.statusBar.setTitle("VP")
                self.showError(message)

            case .empty:
                self.pendingPartialHint = nil
                self.endProcessing()
                self.recordEmptyResult()
            }
        }
    }

    @objc private func handleAppDidBecomeActive() {
        updateAccessibilityDependentFeatures()
    }
}

// MARK: - Onboarding Window

/// 首次运行引导：欢迎 → 开启辅助功能（必做）→ 开启麦克风 → 全部就绪（试用期免配 API，直接开始用）。
/// 全部 UI 走 AppKit，避免新增源文件（项目源文件在 pbxproj 中显式列出）。
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    // 黑白清爽配色，与设置窗口一致；减少大面积灰底，保留绿色完成态。
    // 属性名保留（amber/badge… 只是历史命名，值已是中性灰，别"修"）。
    private enum Palette {
        static let accent = NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x13 / 255, alpha: 1)  // 近黑强调
        static let bg = NSColor.white
        static let card = NSColor.white
        static let text = NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x13 / 255, alpha: 1)
        static let text2 = NSColor(srgbRed: 0x3F / 255, green: 0x3F / 255, blue: 0x43 / 255, alpha: 1)
        static let dotOff = NSColor(srgbRed: 0xE8 / 255, green: 0xE8 / 255, blue: 0xEA / 255, alpha: 1)
        static let amber = NSColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1)   // 等待态文字＝中性灰
        static let green = NSColor(srgbRed: 0x2E / 255, green: 0x87 / 255, blue: 0x62 / 255, alpha: 1)   // 就绪绿（Mac 同款 #2E8762）
        // 图标徽章：轻量浅灰渐变
        static let badgeTop = NSColor(srgbRed: 0xF8 / 255, green: 0xF8 / 255, blue: 0xF9 / 255, alpha: 1)
        static let badgeBottom = NSColor(srgbRed: 0xF0 / 255, green: 0xF0 / 255, blue: 0xF2 / 255, alpha: 1)
        // 绿色「完成」徽章渐变（保留：完成步骤的成功语义）
        static let badgeGreenTop = NSColor(srgbRed: 0xE4 / 255, green: 0xF5 / 255, blue: 0xEC / 255, alpha: 1)
        static let badgeGreenBottom = NSColor(srgbRed: 0xC9 / 255, green: 0xEB / 255, blue: 0xD8 / 255, alpha: 1)
        // 状态药丸底色：等待态＝轻浅灰；完成态＝浅绿（保留语义）
        static let pillAmberBg = NSColor(srgbRed: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF5 / 255, alpha: 1)
        static let pillGreenBg = NSColor(srgbRed: 0xE4 / 255, green: 0xF5 / 255, blue: 0xEC / 255, alpha: 1)
    }

    private weak var appDelegate: AppDelegate?

    private var window: NSWindow?
    private var pollTimer: Timer?
    private var step = 0
    private let stepCount = 4

    // 一次性自动推进的去抖标记
    private var didAutoAdvanceFromAccessibility = false
    private var didAutoAdvanceFromMic = false
    private var didAutoAdvanceFromAPI = false

    // 步骤内容容器（每次切步重建）
    private let stepDotsRow = NSStackView()
    private let contentBox = NSView()

    var isVisible: Bool { window?.isVisible ?? false }

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }

    // MARK: Presentation

    func present() {
        if window == nil { buildWindow() }
        step = 0
        didAutoAdvanceFromAccessibility = false
        didAutoAdvanceFromMic = false
        didAutoAdvanceFromAPI = false
        renderStep()
        startPolling()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Typefree"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.backgroundColor = Palette.bg

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 500))
        root.wantsLayer = true
        root.layer?.backgroundColor = Palette.bg.cgColor

        // 步骤指示点
        stepDotsRow.orientation = .horizontal
        stepDotsRow.spacing = 8
        stepDotsRow.translatesAutoresizingMaskIntoConstraints = false

        contentBox.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stepDotsRow)
        root.addSubview(contentBox)

        // 步骤点沉底（距底 ~22px），内容块在剩余空间内垂直+水平居中。
        NSLayoutConstraint.activate([
            stepDotsRow.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stepDotsRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),

            contentBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 44),
            contentBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -44),
            // 垂直居中于标题栏与步骤点之间的区域。
            contentBox.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            contentBox.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 48),
            contentBox.bottomAnchor.constraint(lessThanOrEqualTo: stepDotsRow.topAnchor, constant: -16),
        ])

        win.contentView = root
        window = win
    }

    // MARK: Step rendering

    private func renderStep() {
        rebuildDots()
        contentBox.subviews.forEach { $0.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(stack)
        // stack 撑满 contentBox（contentBox 本身在窗口中垂直居中），保证内容块整体居中。
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentBox.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
        ])

        switch step {
        case 0: buildWelcome(into: stack)
        case 1: buildAccessibility(into: stack)
        case 2: buildMicrophone(into: stack)
        default: buildDone(into: stack)
        }

        // 除欢迎页外，底部给一排导航：「← 上一步」+（非末步且条件满足）「下一步 →」。
        // 手动导航后关掉自动跳过，避免来回弹。
        if step > 0 {
            let nav = NSStackView()
            nav.orientation = .horizontal
            nav.spacing = 12
            nav.addArrangedSubview(makeTertiaryButton("← 上一步") { [weak self] in
                guard let self = self else { return }
                self.suspendAutoAdvance()
                self.goTo(step: self.step - 1)
            })

            // 末步（完成）用「开始使用」收尾，不放"下一步"；
            // 权限步必需授权，未授权时不放"下一步"（授权后会自动前进）。
            let isLastStep = (step >= stepCount - 1)
            if !isLastStep && currentStepSatisfied() {
                nav.addArrangedSubview(makeTertiaryButton("下一步 →") { [weak self] in
                    guard let self = self else { return }
                    self.suspendAutoAdvance()
                    self.goTo(step: self.step + 1)
                })
            }

            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(nav)
        }
    }

    private func rebuildDots() {
        stepDotsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for i in 0..<stepCount {
            let dot = NSView()
            dot.wantsLayer = true
            dot.translatesAutoresizingMaskIntoConstraints = false
            let active = (i == step)
            // 激活点为加长的橙色胶囊，其余为 7px 圆点。
            let height: CGFloat = 7
            let width: CGFloat = active ? 22 : 7
            dot.layer?.cornerRadius = height / 2
            dot.layer?.backgroundColor = (active ? Palette.accent : Palette.dotOff).cgColor
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: width),
                dot.heightAnchor.constraint(equalToConstant: height),
            ])
            stepDotsRow.addArrangedSubview(dot)
        }
    }

    // MARK: Step content builders

    private func buildWelcome(into stack: NSStackView) {
        stack.addArrangedSubview(makeBadge("🎙️"))
        stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makeTitle("欢迎使用 Typefree"))
        stack.addArrangedSubview(makeBody("按住快捷键说话，松手就贴上整理好的文字。简单几步就能开始。"))
        stack.setCustomSpacing(30, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makePrimaryButton("开始设置") { [weak self] in
            self?.goTo(step: 1)
        })
    }

    private func buildAccessibility(into stack: NSStackView) {
        stack.addArrangedSubview(makeBadge("🔑"))
        stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makeTitle("开启辅助功能"))
        stack.addArrangedSubview(makeBody("用于监听快捷键、把文字贴到光标处。"))
        stack.setCustomSpacing(30, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(makePrimaryButton("打开辅助功能设置") { [weak self] in
            self?.appDelegate?.openAccessibilitySettings()
        })

        let granted = appDelegate?.onboardingHasAccessibility() ?? false
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makeStatusPill(granted ? "✓ 已授权" : "等待授权…", done: granted))
        // 该步骤强制：未授权无法继续，没有跳过按钮。
    }

    private func buildMicrophone(into stack: NSStackView) {
        stack.addArrangedSubview(makeBadge("🎤"))
        stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makeTitle("开启麦克风"))
        stack.addArrangedSubview(makeBody("用来录下你的声音，再转成文字。"))
        stack.setCustomSpacing(30, after: stack.arrangedSubviews.last!)

        let authorized = appDelegate?.onboardingHasMicrophone() ?? false
        if authorized {
            stack.addArrangedSubview(makeStatusPill("✓ 已授权", done: true))
        } else {
            // 已拒绝时系统弹窗弹不出来，只能去系统设置开；未决则可直接弹授权框。
            let denied = appDelegate?.onboardingMicrophoneDenied() ?? false
            stack.addArrangedSubview(makePrimaryButton(denied ? "去系统设置开启" : "开启麦克风") { [weak self] in
                self?.appDelegate?.onboardingRequestMicrophone()
            })
            stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(makeStatusPill(denied ? "已拒绝 · 点上面到系统设置开启" : "等待授权…", done: false))
        }
    }

    private func buildDone(into stack: NSStackView) {
        // 试用期内无需配置 API（走内置试用通道），所以最后一步统一报「就绪」、不催填 key，
        // 直接告诉用户按哪个热键开始。试用到期再到「设置 → 模型」填自己的 key（永久免费）。
        let hotkey = RecordingHotkeyShortcut.current.displayName
        stack.addArrangedSubview(makeBadge("✓", green: true))
        stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!)
        // 自编译的开源版没有试用通道：得先填 Key 才能用，别报「就绪」
        let selfBuilt = !TrialManager.shared.isTrialAvailable
        stack.addArrangedSubview(makeTitle(selfBuilt ? "还差一步" : "全部就绪"))
        stack.addArrangedSubview(makeBody(selfBuilt
            ? "这个版本不含试用通道。先到「设置 → 模型」填入自己的 API Key，然后按住 \(hotkey) 说话。"
            : "按住 \(hotkey) 说话，松手就贴上整理好的文字。"))
        stack.setCustomSpacing(30, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makePrimaryButton("开始使用") { [weak self] in
            self?.finish()
        })
    }

    // MARK: Navigation

    private func goTo(step newStep: Int) {
        guard newStep != step else { return }
        step = max(0, min(stepCount - 1, newStep))
        renderStep()
    }

    /// 用户手动前后翻页后，关掉所有自动跳过，避免又被自动弹走。
    private func suspendAutoAdvance() {
        didAutoAdvanceFromAccessibility = true
        didAutoAdvanceFromMic = true
        didAutoAdvanceFromAPI = true
    }

    /// 当前步的"前进条件"是否满足（权限步需对应权限已授权）。
    private func currentStepSatisfied() -> Bool {
        switch step {
        case 1: return appDelegate?.onboardingHasAccessibility() ?? false
        case 2: return appDelegate?.onboardingHasMicrophone() ?? false
        default: return true
        }
    }

    private func finish() {
        appDelegate?.markOnboardingCompleted()
        stopPolling()
        window?.orderOut(nil)
        // 一律进首页：新用户走试用、无需配 key，不再把人甩到「模型」页填 key。
        // （3.0 起首页会先盖一层新手势演示，看完才进正式页面）
        appDelegate?.showSettingsCenter()
    }

    // MARK: Auto-detect polling

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func tick() {
        guard isVisible else { return }
        switch step {
        case 1:
            if appDelegate?.onboardingHasAccessibility() == true {
                // 刷新状态（renderStep 会读到最新值显示「✓ 已授权」）
                if !didAutoAdvanceFromAccessibility {
                    didAutoAdvanceFromAccessibility = true
                    renderStep()  // 先翻成绿色已授权
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self = self, self.step == 1 else { return }
                        self.goTo(step: 2)
                    }
                }
            }
        case 2:
            if appDelegate?.onboardingHasMicrophone() == true {
                if !didAutoAdvanceFromMic {
                    didAutoAdvanceFromMic = true
                    renderStep()  // 先翻成绿色已授权
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self = self, self.step == 2 else { return }
                        self.goTo(step: 3)
                    }
                }
            }
        default:
            break
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    // MARK: UI factory helpers

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    /// 圆角渐变图标徽章（~72×72，圆角 ~20，柔和阴影），中间放 emoji 字形。
    private func makeBadge(_ glyph: String, green: Bool = false) -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer?.cornerRadius = 20
        badge.layer?.masksToBounds = false

        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        gradient.cornerRadius = 20
        // 145° 对角渐变（左上 → 右下）
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        if green {
            gradient.colors = [Palette.badgeGreenTop.cgColor, Palette.badgeGreenBottom.cgColor]
        } else {
            gradient.colors = [Palette.badgeTop.cgColor, Palette.badgeBottom.cgColor]
        }
        badge.layer?.addSublayer(gradient)

        // 柔和阴影（尺寸固定 72×72，可直接给出 shadowPath 让阴影呈圆角矩形）
        let shadowColor = green ? Palette.green : Palette.accent
        badge.layer?.shadowColor = shadowColor.cgColor
        badge.layer?.shadowOpacity = green ? 0.16 : 0.18
        badge.layer?.shadowRadius = 8
        badge.layer?.shadowOffset = CGSize(width: 0, height: 3)
        badge.layer?.shadowPath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: 72, height: 72),
            cornerWidth: 20, cornerHeight: 20, transform: nil
        )

        let glyphLabel = NSTextField(labelWithString: glyph)
        glyphLabel.font = .systemFont(ofSize: 32)
        glyphLabel.textColor = green ? Palette.green : Palette.accent
        glyphLabel.alignment = .center
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(glyphLabel)

        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 72),
            badge.heightAnchor.constraint(equalToConstant: 72),
            glyphLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            glyphLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        return badge
    }

    private func makeTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 23, weight: .heavy)
        label.textColor = Palette.text
        label.alignment = .center
        return label
    }

    private func makeBody(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        // 行高放宽（~1.7），更舒展。
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineHeightMultiple = 1.7
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14.5),
            .foregroundColor: Palette.text2,
            .paragraphStyle: style,
        ])
        label.attributedStringValue = attr
        label.alignment = .center
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        return label
    }

    /// 状态药丸：等待 = 琥珀底，完成 = 绿底。
    private func makeStatusPill(_ text: String, done: Bool) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer?.cornerRadius = 13
        pill.layer?.backgroundColor = (done ? Palette.pillGreenBg : Palette.pillAmberBg).cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = done ? Palette.green : Palette.amber
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        return pill
    }

    private func makePrimaryButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title) { action() }
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        button.heightAnchor.constraint(equalToConstant: 94).isActive = true
        // 暖橙主色填充 + 白色标题（.rounded 按钮的 contentTintColor 管不到标题，必须用 attributedTitle）
        button.wantsLayer = true
        button.layer?.cornerRadius = 12
        button.bezelColor = Palette.accent
        button.contentTintColor = .white
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        ])
        // 柔和阴影
        button.layer?.shadowColor = Palette.accent.cgColor
        button.layer?.shadowOpacity = 0.22
        button.layer?.shadowRadius = 6
        button.layer?.shadowOffset = CGSize(width: 0, height: 3)
        button.layer?.masksToBounds = false
        return button
    }

    private func makeTertiaryButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title) { action() }
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.contentTintColor = Palette.text2
        let attr = NSAttributedString(string: title, attributes: [
            .foregroundColor: Palette.text2,
            .font: NSFont.systemFont(ofSize: 13),
        ])
        button.attributedTitle = attr
        return button
    }

    private func makeLinkButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title) { action() }
        button.isBordered = false
        button.bezelStyle = .inline
        let attr = NSAttributedString(string: title, attributes: [
            .foregroundColor: Palette.accent,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        button.attributedTitle = attr
        return button
    }
}

/// 用闭包驱动的 NSButton，避免新增 target/action 选择器
private final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func fire() { handler() }
}

/// 录音开始 / 结束提示音（工单 #1003）。声音由 VoicePolishCore.CueSound 现场合成，启动时预载，播放无延迟。
/// 开关与音色存在 config.json（默认开）；设置 →「音频」里可关。
final class CuePlayer {
    static let shared = CuePlayer()

    static let enabledKey = "cue_sound_enabled"
    static let styleKey = "cue_sound_style"
    static let defaultStyle: CueSound.Style = .fourth
    /// 播放音量：声音本身峰值约 -21dBFS，再乘 0.6 ≈ -25dBFS，与 Typeless 实际播放电平相当（它是 -18dBFS × 0.4）
    static let playbackVolume: Float = 0.6

    private var players: [String: AVAudioPlayer] = [:]

    var isEnabled: Bool {
        get { VoicePolishConfig.shared.bool(forKey: Self.enabledKey, defaultValue: true) }
        set { VoicePolishConfig.shared.save(bool: newValue, forKey: Self.enabledKey) }
    }

    var style: CueSound.Style {
        VoicePolishConfig.shared.string(forKey: Self.styleKey).flatMap(CueSound.Style.init(rawValue:)) ?? Self.defaultStyle
    }

    /// 开关关着时什么都不做；`force` 用于设置页里打开开关时试听一下。
    func play(_ kind: CueSound.Kind, force: Bool = false) {
        guard force || isEnabled else { return }
        guard let player = player(for: style, kind: kind) else { return }
        player.currentTime = 0
        player.play()
    }

    func preload() {
        _ = player(for: style, kind: .start)
        _ = player(for: style, kind: .stop)
    }

    private func player(for style: CueSound.Style, kind: CueSound.Kind) -> AVAudioPlayer? {
        let key = "\(style.rawValue)-\(kind == .start ? "start" : "stop")"
        if let p = players[key] { return p }
        guard let p = try? AVAudioPlayer(data: CueSound.wavData(style: style, kind: kind)) else { return nil }
        p.volume = Self.playbackVolume
        p.prepareToPlay()
        players[key] = p
        return p
    }
}

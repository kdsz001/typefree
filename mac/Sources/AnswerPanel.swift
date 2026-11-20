import AppKit
import SwiftUI

/// 「长按问 AI」的回答面板。做法与 trade-capture 的采访浮窗一致：
/// 通知中心同款的 .popover 磨砂材质 + maskImage 圆角、从屏幕右缘滑入、贴右上角、
/// 内容高度变化时顶右角不动、Esc 关闭。内容用 SwiftUI 排版。
/// 支持：多轮对话（按住面板续聊，面板泛蓝光）、图钉固定、逐字流出、复制。
final class AnswerPanel {
    static var log: ((String) -> Void)?
    private var panel: KeyablePanel?
    private var hosting: FirstMouseHostingView?
    /// 离屏的一份对话内容，只用来量高度（ScrollView 里 SwiftUI 自己报不准）
    private var measure: NSHostingView<TurnsView>?
    let model = AnswerModel()
    private var escMonitor: Any?
    private var mouseUpMonitor: Any?
    private var outsideClickMonitor: Any?
    private var appearanceObserver: NSObjectProtocol?
    // 「点外面缩成小框」：小框静止 4s 后 1s 淡出；鼠标停留 150ms 回满；再离开重新倒计时
    private static let collapsedWidth: CGFloat = 320
    private var dismissTimer: Timer?
    private var hoverTimer: Timer?
    private var hoverSince: Date?
    /// 缩过一次之后才启用「鼠标离开面板就再缩」；新话题 / 固定 / 收起时复位
    private var hoverArmed = false
    /// 点外面时回答还没出完：等出完再缩
    private var collapseWhenDone = false
    /// 续聊录音进行中（面板侧兜底记录，防止 SwiftUI 手势丢了 onEnded 之后录音停不下来）
    private var followUpActive = false
    private static let width: CGFloat = 420
    private static let margin: CGFloat = 14
    /// 正文左右内边距：左右等距，正文居中不偏
    static let contentInset: CGFloat = 18
    /// 对话正文宽度：面板宽 − 两侧内边距。滚动条强制成细的 overlay 样式，
    /// 浮在右侧那 18pt 留白上，不占布局、也压不到字，所以不再额外让出通道
    static var contentWidth: CGFloat { width - contentInset * 2 }

    /// 面板空白处长按到时：开始续聊录音（返回 false = 没开始）
    var onFollowUpStart: (() -> Bool)?
    /// 续聊松手（cancelled = 拖开取消）
    var onFollowUpEnd: ((_ cancelled: Bool) -> Void)?
    /// 面板收起时最后一轮回答还没出完（还在思考 / 出字中）：主程序据此作废这次回答
    var onHideWhileAnswering: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }
    /// 当前话题 id（写历史用；新话题换新 id）
    private(set) var threadID = UUID().uuidString
    var isPinned: Bool { model.pinned }
    /// 本话题已完成的问答对，续聊时作为上下文
    var history: [(question: String, answer: String)] {
        model.turns.filter { $0.state == .answered }.map { ($0.question, $0.answer) }
    }

    /// 新话题：清空重来
    func startThread(question: String) {
        model.turns = [AnswerTurn(question: question)]
        model.headerIndex = 0
        threadID = UUID().uuidString
        resetCollapse()
        present()
    }

    /// 续聊：追加一轮
    func appendQuestion(_ question: String) {
        model.turns.append(AnswerTurn(question: question))
        resetCollapse()
        present()
    }

    func updatePartial(_ text: String) {
        guard let last = model.turns.indices.last else { return }
        model.turns[last].answer = text
        model.turns[last].state = .streaming
        relayout()
    }

    func finish(answer: String) {
        guard let last = model.turns.indices.last else { return }
        model.turns[last].answer = answer
        model.turns[last].state = .answered
        relayout()
        if collapseWhenDone { collapseWhenDone = false; collapse() }
    }

    func fail(_ message: String) {
        guard let last = model.turns.indices.last else { return }
        model.turns[last].answer = message
        model.turns[last].state = .failed
        relayout()
        if collapseWhenDone { collapseWhenDone = false; collapse() }
    }

    /// 录音状态 → 面板蓝光 / 待取消红光；底栏同步换成音浪
    /// 主程序告知：现在正在「长按问 AI」等开口（误触时什么都别动）。为 true 时点面板外面不收起。
    var isAskPending: (() -> Bool)?

    func setRecording(_ recording: Bool, cancelArmed: Bool = false) {
        model.recording = recording
        model.cancelArmed = cancelArmed
        if !recording { followUpActive = false }   // 快捷键停止的续聊不经 endFollowUp，别把状态留着
        if recording { model.footer = .listening; model.wave.start() } else { model.wave.stop(); if model.footer == .listening { model.footer = .idle } }
    }

    /// 底栏状态：识别中 / 没听到 / 已取消 / 恢复提示（后两者 1.6s 后自动恢复）
    func setListening(_ state: AnswerModel.FooterState) {
        model.footer = state
        if state == .noSpeech || state == .cancelled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, self.model.footer == state else { return }
                self.model.footer = .idle
            }
        }
    }

    /// 录音音量（0…1），底栏音浪用
    func updateAudioLevel(_ level: Float) {
        model.wave.level = CGFloat(min(max(level, 0), 1))
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        if let last = model.turns.last, last.state == .thinking || last.state == .streaming { onHideWhileAnswering?() }
        removeEscMonitor()
        removeMouseUpMonitor()
        removeOutsideClickMonitor()
        resetCollapse()
        if followUpActive { endFollowUp(cancelled: true) }
        model.recording = false
        let screen = panel.screen ?? Self.screenUnderMouse()
        var out = panel.frame
        out.origin.x = screen.frame.maxX + 12
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(out, display: true)
            panel.animator().alphaValue = 0.2
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        })
    }

    // MARK: - 私有

    private func present() {
        if panel == nil { createPanel() }
        applyAppearance()   // 兜底：万一漏了切换通知，每次弹出时再核对一次
        guard let panel, let hosting else { return }
        let screen = Self.screenUnderMouse()
        model.maxContentHeight = max(160, screen.visibleFrame.height * 0.7 - 140)   // 140 ≈ 头（两行问题）+ 尾 + 内边距
        // SwiftUI 的内容尺寸要到下一个运行循环才按新内容更新，先同步布局一次再量，
        // 否则会拿到上一条回答的高度，内容悬在中间、上下露出空的磨砂底。
        hosting.layoutSubtreeIfNeeded()
        tuneScroller()   // 弹出这一帧就是细 overlay 滚动条，不会先闪一下系统的粗条
        let size = fittingSize(of: hosting)
        let vf = screen.visibleFrame
        let final = NSRect(x: vf.maxX - size.width - Self.margin, y: vf.maxY - size.height - Self.margin,
                           width: size.width, height: size.height)
        if panel.isVisible {
            // 面板已在屏上（固定着、或上一题还没收）：内容整体换新，窗口直接定到新高度。
            // 若走动画，旧窗口比新内容高的那 0.2 秒里内容会贴底、顶上露一块空底。
            panel.setFrame(final, display: true)
            if let content = panel.contentView { hosting.frame = content.bounds }
            panel.invalidateShadow()
            relayout()
            return
        }
        let start = NSRect(x: screen.frame.maxX + 12, y: final.origin.y, width: size.width, height: size.height)
        panel.alphaValue = 1
        // 先定窗口尺寸，再把内容视图铺满：内容视图带自动缩放，若先设它再改窗口，会随窗口尺寸差被二次缩放，
        // 上次面板高、这次内容短时内容就被挤到底部、顶上露一块空底
        panel.setFrame(start, display: false)
        if let content = panel.contentView { hosting.frame = content.bounds }
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.19, 1.0, 0.22, 1.0)
            panel.animator().setFrame(final, display: true)
        }, completionHandler: { [weak self] in
            panel.invalidateShadow()
            self?.relayout()
        })
        installEscMonitor()
        installMouseUpMonitor()
        installOutsideClickMonitor()
    }

    private func createPanel() {
        measure = NSHostingView(rootView: TurnsView(model: model, width: Self.contentWidth))
        let view = AnswerView(model: model,
                              onCopy: { [weak self] in self?.copyAnswer() },
                              onClose: { [weak self] in self?.hide() },
                              onTogglePin: { [weak self] in self?.togglePin() },
                              onHoldStart: { [weak self] in self?.beginFollowUp() ?? false },
                              onHoldEnd: { [weak self] cancelled in self?.endFollowUp(cancelled: cancelled) })
        let hosting = FirstMouseHostingView(rootView: view)
        let size = fittingSize(of: hosting)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 22)
        effect.addSubview(hosting)

        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = effect
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // 与底部胶囊同层（胶囊窗口 isFloatingPanel 实际是 floating 层）：续聊时胶囊后显示、压在面板上方
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isMovable = false
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.onEscape = { [weak self] in self?.hide() }
        panel = p
        self.hosting = hosting
        // 深浅跟「设置 → 外观」走（与主窗口一致）；内容全是系统色 + 固定蓝，深色时自动成深色磨砂
        MainWindowAppearance.observeSystemChanges()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: MainWindowAppearance.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyAppearance() }
        applyAppearance()
    }

    private func applyAppearance() {
        guard let panel else { return }
        let appearance = MainWindowAppearance.resolve()
        if panel.appearance?.name != appearance.name { panel.appearance = appearance }
    }

    private func fittingSize(of hosting: FirstMouseHostingView) -> NSSize {
        if let measure {
            measure.layoutSubtreeIfNeeded()
            let h = measure.fittingSize.height
            if h > 1, abs(h - model.contentHeight) > 0.5 {
                model.contentHeight = h
                hosting.layoutSubtreeIfNeeded()
            }
        }
        var size = hosting.fittingSize
        if size.width < 10 || size.height < 10 { size = NSSize(width: Self.width, height: 120) }
        size.width = model.collapsed ? Self.collapsedWidth : Self.width
        return size
    }

    /// 内容高度变了 → 面板跟着长/缩，顶右角不动；对话超过上限后始终滚到最新一轮
    private func relayout() {
        guard let panel, let hosting else { return }
        DispatchQueue.main.async {
            hosting.layoutSubtreeIfNeeded()
            self.tuneScroller()
            let target = self.fittingSize(of: hosting)
            let current = panel.frame
            self.scrollToBottom()
            guard abs(target.height - current.height) > 0.5 || abs(target.width - current.width) > 0.5 else { return }
            AnswerPanel.log?(String(format: "AnswerPanel relayout content=%.1f target=%.1f current=%.1f", self.model.contentHeight, target.height, current.height))
            let frame = NSRect(x: current.maxX - target.width, y: current.maxY - target.height,
                               width: target.width, height: target.height)
            // 流式出字期间每段都会长高：不做动画，直接定到新高度。动画途中窗口比内容矮，
            // 文字会被往上挤、一段一跳；逐字流出本身就是过渡，不需要再补动画。
            if self.model.turns.last?.state == .streaming {
                panel.setFrame(frame, display: true)
                if let content = panel.contentView { hosting.frame = content.bounds }
                panel.invalidateShadow()
                self.scrollToBottom()
                return
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.9, 0.3, 1.0)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self, weak panel, weak hosting] in
                guard let panel, let hosting, let content = panel.contentView else { return }
                hosting.frame = content.bounds
                panel.invalidateShadow()
                self?.scrollToBottom()
            })
        }
    }

    private func beginFollowUp() -> Bool {
        guard !followUpActive, onFollowUpStart?() == true else { return false }
        followUpActive = true
        return true
    }

    private func endFollowUp(cancelled: Bool) {
        guard followUpActive else { return }
        followUpActive = false
        onFollowUpEnd?(cancelled)
    }

    /// 兜底：不管哪个子视图吞了事件，本 App 收到「左键松开」就结束续聊录音
    private func installMouseUpMonitor() {
        removeMouseUpMonitor()
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, self.followUpActive else { return event }
            DispatchQueue.main.async { self.endFollowUp(cancelled: self.model.cancelArmed) }
            return event
        }
    }

    /// 没固定时，点面板外任何地方就收起（全局监听收不到自己窗口里的点击，所以面板内点击天然不算）
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.model.pinned, self.panel?.isVisible == true, !self.model.collapsed else { return }
            // 用户在别处长按提问：等他开口再收（feedAskSpeechDetector 里 hide），误触时面板原地不动
            if self.isAskPending?() == true { return }
            self.collapse()
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
    }

    private func removeMouseUpMonitor() {
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor); self.mouseUpMonitor = nil }
    }

    // MARK: - 点外面缩成小框

    private func collapse() {
        guard let panel, panel.isVisible, !model.pinned, !model.collapsed else { return }
        // 回答还在出 / 正在录音：先不缩，出完再缩
        if model.recording || model.turns.last.map({ $0.state == .thinking || $0.state == .streaming }) == true {
            collapseWhenDone = true
            return
        }
        model.collapsed = true
        hoverArmed = true
        relayout()
        startDismissCountdown()
        startHoverPolling()
    }

    private func expand() {
        cancelDismissCountdown()
        guard model.collapsed else { return }
        model.collapsed = false
        relayout()
    }

    private func togglePin() {
        model.pinned.toggle()
        if model.pinned {
            // 小框上点图钉 = 我要留着：直接展开并固定
            cancelDismissCountdown()
            stopHoverPolling()
            hoverArmed = false
            collapseWhenDone = false
            if model.collapsed { model.collapsed = false; relayout() }
        }
    }

    private func resetCollapse() {
        cancelDismissCountdown()
        stopHoverPolling()
        hoverArmed = false
        collapseWhenDone = false
        if model.collapsed { model.collapsed = false }
    }

    /// 小框静止 4s，最后 1s 淡出，然后收起
    private func startDismissCountdown() {
        dismissTimer?.invalidate()
        panel?.alphaValue = 1
        let t = Timer(timeInterval: 4.0, repeats: false) { [weak self] _ in
            guard let self, let panel = self.panel, self.model.collapsed else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 1.0
                panel.animator().alphaValue = 0.1
            }, completionHandler: { [weak self] in
                guard let self, self.model.collapsed, self.dismissTimer != nil else { return }
                self.hide()
            })
        }
        RunLoop.main.add(t, forMode: .common)
        dismissTimer = t
    }

    private func cancelDismissCountdown() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 1
        }
    }

    /// 20Hz 看鼠标在不在面板上：小框上停留 150ms 才算「回来」（去菜单栏顺路擦过不算）；回满后离开就再缩
    private func startHoverPolling() {
        guard hoverTimer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.hoverTick() }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func stopHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverSince = nil
    }

    private func hoverTick() {
        guard let panel, panel.isVisible, hoverArmed, !model.pinned else { stopHoverPolling(); return }
        let inside = NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
        if model.collapsed {
            if inside {
                if hoverSince == nil { hoverSince = Date() }
                if Date().timeIntervalSince(hoverSince!) >= 0.15 { hoverSince = nil; expand() }
            } else {
                hoverSince = nil
            }
        } else if !inside, !model.recording {
            collapse()
        }
    }

    /// 找到 SwiftUI ScrollView 背后的 NSScrollView，直接滚到底
    private func scrollToBottom() {
        guard model.turns.count > 1 else { return }   // 只有一轮长回答时停在开头，从上往下读
        guard let hosting, let sv = Self.findScrollView(in: hosting), let doc = sv.documentView else { return }
        sv.layoutSubtreeIfNeeded()
        let clipH = sv.contentView.bounds.height
        let docH = doc.frame.height
        guard docH > clipH + 0.5 else { return }
        let y = doc.isFlipped ? docH - clipH : 0
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    /// 滚动条收细：强制细一号的 overlay 样式 —— 不占布局、不滚动时自动淡出、贴着面板右内缘。
    /// 系统设成「始终显示滚动条」时也照样 overlay：这是悬浮面板，与通知中心同款做法
    private func tuneScroller() {
        guard let hosting, let sv = Self.findScrollView(in: hosting) else { return }
        if sv.scrollerStyle != .overlay { sv.scrollerStyle = .overlay }
        sv.autohidesScrollers = true
        sv.scrollerKnobStyle = .default
        if let scroller = sv.verticalScroller {
            if scroller.controlSize != .small { scroller.controlSize = .small }
            scroller.scrollerStyle = .overlay
        }
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        for sub in view.subviews {
            if let sv = sub as? NSScrollView { return sv }
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    /// 「复制」复制标题栏正显示的那一轮回答（标题跟着滚动走，看的是哪轮就复制哪轮）
    private var lastAnswer: String? {
        let i = model.headerIndex
        if model.turns.indices.contains(i), model.turns[i].state == .answered { return model.turns[i].answer }
        return model.turns.last(where: { $0.state == .answered })?.answer
    }

    private func copyAnswer() {
        guard let text = lastAnswer, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Self.plainText(fromMarkdown: text), forType: .string)
        model.copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.model.copied = false }
    }

    /// 复制到别处用纯文本：小标题去掉 #、加粗去掉 **、条目统一成「• 」/「1. 」、多余空行合并
    static func plainText(fromMarkdown md: String) -> String {
        var lines: [String] = []
        for raw in md.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { line = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: #"^[-•·*]\s+"#, with: "• ", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(\d+)[.、)）]\s+"#, with: "$1. ", options: .regularExpression)
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }   // 合并连续空行、去掉开头空行
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func installEscMonitor() {
        removeEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel, event.keyCode == 53 else { return event }
            self.hide()
            return nil
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor); self.escMonitor = nil }
    }

    private static func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// 可拉伸的圆角遮罩图（NSVisualEffectView 官方圆角姿势）
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// 面板平时不是 key window（用户在别的 App 里），第一下按下默认会被系统吞掉去「激活窗口」，
/// 长按续聊就收不到；声明接受第一下鼠标，按下即达。
private final class FirstMouseHostingView: NSHostingView<AnswerView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 无边框面板默认不能成为 key window，选文字 / Esc 都需要它能
private final class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - 数据

struct AnswerTurn: Identifiable {
    enum State { case thinking, streaming, answered, failed }
    let id = UUID()
    let question: String
    var answer = ""
    var state: State = .thinking
}

final class AnswerModel: ObservableObject {
    @Published var turns: [AnswerTurn] = []
    @Published var pinned = false
    @Published var recording = false
    @Published var cancelArmed = false
    @Published var copied = false
    enum FooterState { case idle, listening, processing, noSpeech, cancelled }
    @Published var footer: FooterState = .idle
    let wave = PanelWaveClock()
    @Published var maxContentHeight: CGFloat = 400
    /// 标题栏显示第几轮的问题（跟着滚动走：哪一轮的问句块滚出顶部，标题就换成哪一轮）
    @Published var headerIndex = 0
    /// 点外面后缩成只剩一行问题的小框
    @Published var collapsed = false
    @Published var contentHeight: CGFloat = 40
}

// MARK: - 视图

struct AnswerView: View {
    @ObservedObject var model: AnswerModel
    let onCopy: () -> Void
    let onClose: () -> Void
    let onTogglePin: () -> Void
    let onHoldStart: () -> Bool
    let onHoldEnd: (_ cancelled: Bool) -> Void

    @State private var pressStart: CGPoint?
    @State private var holdTimer: Timer?
    @State private var holdActive = false
    @State private var dragCancel = false

    private let accent = Color(red: 0.25, green: 0.52, blue: 1.0)   // 与提问模式的蓝色光环同色
    private let cancelRed = Color(red: 1.0, green: 0.31, blue: 0.27)

    var body: some View {
        Group {
            if model.collapsed { chip } else { full }
        }
        // 在毛玻璃上再垫一层半透明底色：复杂背景下文字依然清晰（通知中心同款思路）
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        .contentShape(Rectangle())
        .gesture(holdGesture)
        // 续聊录音时的蓝光 / 待取消红光，与胶囊同款
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(model.cancelArmed ? cancelRed : accent, lineWidth: 1.5)
                .shadow(color: (model.cancelArmed ? cancelRed : accent).opacity(0.55), radius: 10)
                .opacity(model.recording ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: model.recording)
                .animation(.easeOut(duration: 0.12), value: model.cancelArmed)
        )
    }

    /// 小框：一行问题 + 图钉 + 关闭。按钮与展开后的标题栏按钮位置对齐（都靠右上角），
    /// 鼠标停上去展开时按钮仍在指针下面，能直接点到
    @ViewBuilder private var chip: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 4, height: 22)
            Text(model.turns.last?.question ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            HoverIconButton(systemName: model.pinned ? "pin.fill" : "pin", tint: model.pinned ? accent : nil, action: onTogglePin)
                .help("固定面板")
            HoverIconButton(systemName: "xmark", tint: nil, action: onClose)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 18)
        .frame(width: 320)
    }

    @ViewBuilder private var full: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, AnswerPanel.contentInset)
            ScrollView(.vertical, showsIndicators: true) {
                TurnsView(model: model, width: AnswerPanel.contentWidth)
                    .padding(.horizontal, AnswerPanel.contentInset)
            }
            .coordinateSpace(name: "answerScroll")
            .onPreferenceChange(TurnTopKey.self) { tops in
                // 某一轮的问句块进入可视区上半部分 → 标题换成这一轮（此时它的内容已盖住上一轮）
                let threshold = min(model.contentHeight, model.maxContentHeight) * 0.5
                let idx = tops.filter { $0.value <= threshold }.keys.max() ?? 0
                if idx != model.headerIndex { model.headerIndex = idx }
            }
            // 高度由 AnswerPanel 离屏实测后写入 model，超过上限才滚动；滚到底由 AppKit 侧做（SwiftUI 的 scrollTo 在 macOS 上跟不上内容增长）
            .frame(height: min(max(model.contentHeight, 24), model.maxContentHeight))
            footer
                .padding(.horizontal, AnswerPanel.contentInset)
        }
        .padding(.vertical, 18)
        .frame(width: 420)
    }

    // MARK: 头

    private var headerTurn: Int { min(max(model.headerIndex, 0), max(model.turns.count - 1, 0)) }

    @ViewBuilder private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.recording ? "正在听…" : (model.turns.count > 1 ? "问 AI · 第 \(headerTurn + 1) 轮" : "问 AI"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text(model.turns.indices.contains(headerTurn) ? model.turns[headerTurn].question : "")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            HoverIconButton(systemName: model.pinned ? "pin.fill" : "pin", tint: model.pinned ? accent : nil, action: onTogglePin)
                .help(model.pinned ? "已固定：下次说话时不会自动收起" : "固定面板")
            HoverIconButton(systemName: "xmark", tint: nil, action: onClose)
        }
    }

    // MARK: 尾

    @ViewBuilder private var footer: some View {
        ZStack {
            // 录音：音浪居中，用面板的蓝（拖开待取消时随光环变红）；提示文字让位
            if model.footer == .listening {
                PanelWave(clock: model.wave, color: model.cancelArmed ? cancelRed : accent)
            }
            footerRow
        }
        .frame(height: 26)
    }

    @ViewBuilder private var footerRow: some View {
        HStack(spacing: 4) {
            switch model.footer {
            case .idle:
                Text("长按任意位置继续提问")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            case .listening:
                Color.clear.frame(width: 1, height: 1)
            case .processing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("识别中").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .noSpeech:
                Text("没听到问题").font(.system(size: 11)).foregroundStyle(.secondary)
            case .cancelled:
                Text("已取消").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.turns.contains(where: { $0.state == .answered }) {
                GhostTextButton(title: model.copied ? "已复制" : "复制", action: onCopy)
            }
        }
    }

    // MARK: 长按续聊

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if model.collapsed { return }   // 小框上不续聊：先停留展开
                if pressStart == nil {
                    pressStart = value.startLocation
                    dragCancel = false
                    holdActive = false
                    holdTimer?.invalidate()
                    let timer = Timer(timeInterval: 0.45, repeats: false) { _ in
                        DispatchQueue.main.async {
                            guard pressStart != nil, !holdActive else { return }
                            if onHoldStart() { holdActive = true }
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)   // 按住期间的事件追踪模式下也要能到时
                    holdTimer = timer
                }
                guard let start = pressStart else { return }
                let d = hypot(value.location.x - start.x, value.location.y - start.y)
                if !holdActive {
                    if d > 6 { holdTimer?.invalidate(); pressStart = nil }   // 还没到时就动了：当拖动
                } else {
                    let armed = dragCancel ? d > 45 : d >= 70
                    if armed != dragCancel { dragCancel = armed; model.cancelArmed = armed }
                }
            }
            .onEnded { _ in
                holdTimer?.invalidate()
                holdTimer = nil
                if holdActive { onHoldEnd(dragCancel) }
                holdActive = false
                dragCancel = false
                pressStart = nil
            }
    }
}

/// 对话正文：首轮回答 + 之后每轮「问句块 + 回答」。同一份视图既显示也离屏测高。
struct TurnsView: View {
    @ObservedObject var model: AnswerModel
    /// 显示与离屏测高用同一个宽度，换行才一致
    let width: CGFloat
    private let accent = Color(red: 0.25, green: 0.52, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(model.turns.enumerated()), id: \.element.id) { index, turn in
                let isLast = index == model.turns.count - 1
                VStack(alignment: .leading, spacing: 12) {
                if index > 0 {
                    // 追问：灰底问句块，与回答一眼分开
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(accent.opacity(isLast ? 1 : 0.45))
                            .frame(width: 3)
                        Text(turn.question)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .padding(.top, 4)
                }
                answerBody(turn)
                    .opacity(isLast ? 1 : 0.72)   // 旧的几轮压暗，视线落在最新一轮
                    .id(turn.id)
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: TurnTopKey.self, value: [index: g.frame(in: .named("answerScroll")).minY])
                })
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func answerBody(_ turn: AnswerTurn) -> some View {
        switch turn.state {
        case .thinking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在思考…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .streaming, .answered:
            AnswerText(text: turn.answer)
        case .failed:
            Text(turn.answer)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 回答正文：轻量 Markdown —— 空行分段、「### 」小标题、「- 」「1. 」条目（悬挂缩进）、**加粗**；正文 15 号、行距 6
struct AnswerText: View {
    let text: String
    private let body15 = Font.system(size: 15)

    private enum Block { case heading(String), paragraph(String), bullet(String), numbered(String, String) }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para.removeAll() }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { out.append(.heading(title)) }
                continue
            }
            if let r = line.range(of: #"^(?:[-•·*]|\d+[.、)）])\s+"#, options: .regularExpression) {
                flush()
                let marker = String(line[r.lowerBound..<r.upperBound]).trimmingCharacters(in: .whitespaces)
                let body = String(line[r.upperBound...])
                if marker.first?.isNumber == true {
                    let num = marker.trimmingCharacters(in: CharacterSet(charactersIn: ".、)）")) + "."
                    out.append(.numbered(num, body))
                } else {
                    out.append(.bullet(body))
                }
            } else {
                para.append(line)
            }
        }
        flush()
        return out
    }

    /// 行内 Markdown（加粗/斜体）→ Text；解析失败或流式中途符号不配对时按纯文本显示
    private func inline(_ s: String) -> Text {
        if s.contains("*") || s.contains("`"),
           let attr = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let s):
                    inline(s).font(.system(size: 15, weight: .semibold))
                        .padding(.top, index == 0 ? 0 : 6)
                        .fixedSize(horizontal: false, vertical: true)
                case .paragraph(let s):
                    inline(s).font(body15).lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(body15).foregroundStyle(.secondary)
                        inline(s).font(body15).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(n).font(body15).foregroundStyle(.secondary).monospacedDigit()
                            .frame(minWidth: 18, alignment: .trailing)
                        inline(s).font(body15).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HoverIconButton: View {
    let systemName: String
    let tint: Color?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint ?? (hovering ? Color.primary : Color.secondary))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0.055)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 面板底栏音浪的时钟：60Hz、common 模式（按住鼠标时主线程在追踪模式，默认模式定时器和 TimelineView 都不走）。
/// 算法与 SiriCapsuleView.tick 完全一样：快起慢落 + 目标值衰减 + 钟形包络 + 三个正弦叠加 + 抖动。
final class PanelWaveClock: ObservableObject {
    // 几何直接复用鼠标长按胶囊（pillW 72、无按钮）：9 根、条宽 (52−12)/9−1.5≈2.94、间距 1.5、最高 pillH−6=28、区域高 34
    static let bars = 9
    @Published var heights: [CGFloat] = Array(repeating: 3, count: PanelWaveClock.bars)
    var level: CGFloat = 0
    private var smooth: CGFloat = 0
    private var time: Double = 0
    private var timer: Timer?
    let maxHeight: CGFloat = 28

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        level = 0
        smooth = 0
        heights = Array(repeating: 3, count: Self.bars)
    }

    private func tick() {
        if level > smooth { smooth += (level - smooth) * 0.4 } else { smooth += (level - smooth) * 0.08 }
        level *= 0.92
        time += 0.016 * 1.2
        let energy = max(smooth, 0.15)
        var next = heights
        for i in 0..<Self.bars {
            let pos = CGFloat(i) / CGFloat(Self.bars - 1)
            let bell = exp(-pow((pos - 0.5) * 2.0, 2))
            let wave = 0.6 + sin(time * 4.0 + Double(i) * 0.4) * 0.3 + sin(time * 6.5 + Double(i) * 0.7) * 0.2 + sin(time * 3.0 + Double(i) * 0.2) * 0.15
            let jitter = CGFloat.random(in: -1.5...1.5) * energy * 4
            let target = max(3, min(maxHeight, 3 + pow(energy, 0.7) * maxHeight * bell * CGFloat(wave) + jitter))
            next[i] += (target - next[i]) * 0.4
        }
        heights = next
    }
}

/// 面板底栏音浪：没有黑底，用面板的颜色画竖条
private struct PanelWave: View {
    @ObservedObject var clock: PanelWaveClock
    let color: Color
    private let barW: CGFloat = (52 - 12) / 9 - 1.5
    private let gap: CGFloat = 1.5

    var body: some View {
        Canvas { g, size in
            for (i, raw) in clock.heights.enumerated() {
                let h = max(raw, 3)
                let rect = CGRect(x: CGFloat(i) * (barW + gap), y: (size.height - h) / 2, width: barW, height: h)
                // 与胶囊同款：越高越亮，短条也不发灰
                g.fill(Path(roundedRect: rect, cornerRadius: barW / 2), with: .color(color.opacity(0.75 + 0.25 * (h / clock.maxHeight))))
            }
        }
        .frame(width: CGFloat(PanelWaveClock.bars) * (barW + gap) - gap, height: 34)
    }
}

/// 小胶囊按钮：与右上角圆形图标按钮同一套灰底，悬停加深
private struct GhostTextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .padding(.vertical, 5)
                .padding(.horizontal, 11)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.10 : 0.055)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 每一轮在滚动区里的顶边 y（滚动坐标系），用来决定标题栏显示哪一轮
private struct TurnTopKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

import AppKit

/// 画面上のウィンドウをクリックして選ぶ (⌘⇧4 → Space と同じ操作感)。
/// 全ディスプレイを透明なオーバーレイで覆い、マウスの下にある一番手前のウィンドウを枠で示す。
final class WindowPicker {
    /// z 順 (手前から) に並んだ画面上のウィンドウ 1 枚分
    struct ScreenWindow {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        /// 左上原点のグローバル座標
        let bounds: CGRect
    }

    private var overlays: [NSWindow] = []
    private var monitor: Any?
    private var candidates: [CGWindowID: WindowInfo] = [:]
    private var screenWindows: [ScreenWindow] = []
    private var hidden: [(window: NSWindow, alpha: CGFloat)] = []
    private var completion: ((WindowInfo?) -> Void)?

    var isActive: Bool { completion != nil }

    /// candidates のどれかがクリックされたらそのウィンドウを、キャンセルされたら nil を渡して completion を呼ぶ。
    func start(candidates: [WindowInfo], completion: @escaping (WindowInfo?) -> Void) {
        guard !isActive else { return }
        self.candidates = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.completion = completion
        screenWindows = Self.currentScreenWindows()

        // 自分のウィンドウは透明にしてクリックも通す (後ろのウィンドウを選べるように)
        hidden = NSApp.windows.filter(\.isVisible).map { ($0, $0.alphaValue) }
        for (window, _) in hidden {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }

        overlays = NSScreen.screens.map(makeOverlay)
        NSApp.activate()
        overlays.forEach { $0.orderFrontRegardless() }
        overlays.first { $0.screen == NSScreen.main }?.makeKey()
        NSCursor.crosshair.push()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event)
            return nil
        }
        updateHighlight()
    }

    /// 画面上の点 (左上原点のグローバル座標) にある、一番手前の候補ウィンドウ
    nonisolated static func hitTest(
        _ point: CGPoint, in windows: [ScreenWindow], candidates: Set<CGWindowID>, excludingPID: pid_t
    ) -> CGWindowID? {
        windows.first { window in
            window.pid != excludingPID && window.layer == 0 && window.bounds.contains(point)
        }
        .flatMap { candidates.contains($0.id) ? $0.id : nil }
    }

    // MARK: - Private

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            updateHighlight()
        case .leftMouseDown:
            finish(with: windowUnderMouse())
        case .rightMouseDown:
            finish(with: nil)
        case .keyDown where event.keyCode == 53:  // Esc
            finish(with: nil)
        default:
            break
        }
    }

    private func windowUnderMouse() -> WindowInfo? {
        let id = Self.hitTest(
            Self.globalTopLeftPoint(NSEvent.mouseLocation),
            in: screenWindows,
            candidates: Set(candidates.keys),
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )
        return id.flatMap { candidates[$0] }
    }

    private func updateHighlight() {
        let target = windowUnderMouse()
        for overlay in overlays {
            guard let view = overlay.contentView as? PickerOverlayView else { continue }
            view.highlight = target.map { overlay.convertFromScreen(Self.cocoaRect(fromTopLeft: $0.frame)) }
            view.label = target.map { "\($0.appName) — \($0.displayTitle)" }
        }
    }

    private func finish(with window: WindowInfo?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NSCursor.pop()
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        for (hiddenWindow, alpha) in hidden {
            hiddenWindow.alphaValue = alpha
            hiddenWindow.ignoresMouseEvents = false
        }
        hidden.removeAll()
        let completion = completion
        self.completion = nil
        completion?(window)
    }

    private func makeOverlay(for screen: NSScreen) -> NSWindow {
        let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = PickerOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        return window
    }

    /// 画面上のウィンドウを手前から順に取得する
    private static func currentScreenWindows() -> [ScreenWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsInfo = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
            else { return nil }
            return ScreenWindow(id: id, pid: pid, layer: layer, bounds: bounds)
        }
    }

    /// AppKit の座標 (メインディスプレイ左下原点) を、CGWindow と同じ左上原点の座標にする
    private static func globalTopLeftPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    private static func cocoaRect(fromTopLeft rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }
}

/// Esc を受け取れるよう、枠なしでもキーウィンドウになれるウィンドウ
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// 選択中のウィンドウを枠と名前で示すビュー
private final class PickerOverlayView: NSView {
    var highlight: NSRect? { didSet { needsDisplay = true } }
    var label: String? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // キーウィンドウでない (別ディスプレイの) オーバーレイにもマウス移動を届ける
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBadge("選択するウィンドウをクリック（Esc でキャンセル）", centeredAt: NSPoint(x: bounds.midX, y: bounds.maxY - 60))

        guard let highlight else { return }
        NSColor.systemBlue.withAlphaComponent(0.2).setFill()
        let path = NSBezierPath(roundedRect: highlight, xRadius: 10, yRadius: 10)
        path.fill()
        NSColor.systemBlue.setStroke()
        path.lineWidth = 4
        path.stroke()
        if let label {
            drawBadge(label, centeredAt: NSPoint(x: highlight.midX, y: highlight.midY))
        }
    }

    private func drawBadge(_ text: String, centeredAt point: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let padding = NSSize(width: 14, height: 8)
        let box = NSRect(
            x: point.x - size.width / 2 - padding.width,
            y: point.y - size.height / 2 - padding.height,
            width: size.width + padding.width * 2,
            height: size.height + padding.height * 2
        )
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        string.draw(at: NSPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }
}

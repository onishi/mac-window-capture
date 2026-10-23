import AppKit
import ApplicationServices

/// 対象ウィンドウへのスクロール・キー入力・クリックを合成イベントで送る。アクセシビリティ権限が必要。
struct InputDriver {
    let window: WindowInfo
    /// 撮る範囲の大きさ (ポイント)。中身だけ切り出すときは切り出した範囲、そうでなければウィンドウ全体
    let contentSize: CGSize
    /// スクロールで動く部分の長さ (ポイント)。固定ヘッダーなどを測れたら、その分を除いた長さを入れる
    var scrollableLength: CGFloat?

    init(window: WindowInfo, crop: CropInsets?) {
        self.window = window
        contentSize = crop?.rect(in: window.frame.size)?.size ?? window.frame.size
    }

    /// 1 回のスクロールで動かす量 (ポイント)。撮る範囲の高さ (左右なら幅) に対する割合で決める
    func scrollDistance(_ settings: LoopSettings) -> CGFloat {
        let length = scrollableLength ?? (settings.scrollDirection.isVertical ? contentSize.height : contentSize.width)
        return length * settings.effectiveScrollRatio
    }

    func perform(_ settings: LoopSettings) async throws {
        switch settings.action {
        case .scroll:
            try await moveCursor(to: point(in: settings))
            try await scroll(settings.scrollDirection, distance: scrollDistance(settings))
            try await parkCursor()
        case .key:
            press(settings.key.keyCode)
        case .click:
            let point = point(in: settings)
            try await moveCursor(to: point)
            click(at: point)
            try await parkCursor()
        case .timer:
            break
        }
    }

    /// カーソルを対象ウィンドウのすぐ外へ逃がす。
    /// リンクの上にカーソルがあると、Chrome の左下の URL 表示やホバー時の下線などが写ってしまうため
    func parkCursor() async throws {
        let frame = window.frame
        let candidates = [
            CGPoint(x: frame.maxX + 8, y: frame.midY),
            CGPoint(x: frame.minX - 8, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.maxY + 8),
            CGPoint(x: frame.midX, y: frame.minY - 8),
        ]
        let screens = NSScreen.screens.map { screen in
            // AppKit の座標 (メインディスプレイ左下原点) を左上原点に直す
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        }
        // 画面いっぱいのウィンドウなら外に出せないので、左上の角に置く
        let point = candidates.first { point in screens.contains { $0.contains(point) } }
            ?? CGPoint(x: frame.minX + 2, y: frame.minY + 2)
        try await moveCursor(to: point)
    }

    /// 対象アプリをアクティブにし、対象ウィンドウをそのアプリの最前面に出す。
    func bringToFront() {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        NSApp.yieldActivation(to: app)
        app.activate()

        let appElement = AXUIElementCreateApplication(window.pid)
        AXUIElementSetAttributeValue(appElement, "AXFrontmost" as CFString, kCFBooleanTrue)
        if let element = AX.window(matching: window) {
            AXUIElementPerformAction(element, "AXRaise" as CFString)
        }
    }

    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
    }

    static var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func restoreCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
    }

    // MARK: - Private

    private func point(in settings: LoopSettings) -> CGPoint {
        CGPoint(
            x: window.frame.minX + window.frame.width * settings.pointX,
            y: window.frame.minY + window.frame.height * settings.pointY
        )
    }

    /// mouseMoved イベントでカーソルを動かす (ホバー状態やスクロール先の判定をアプリに更新させるため)
    private func moveCursor(to point: CGPoint) async throws {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .postMarked()
        try await Task.sleep(for: .milliseconds(50))
    }

    /// 一度に大きく動かすとアプリによって無視・加速されるため、小刻みに送る。
    private func scroll(_ direction: ScrollDirection, distance: CGFloat) async throws {
        let step: Int32 = 40
        var remaining = Int32(distance.rounded())
        while remaining > 0 {
            let delta = min(step, remaining)
            let (vertical, horizontal): (Int32, Int32) = switch direction {
            case .down: (-delta, 0)
            case .up: (delta, 0)
            case .right: (0, -delta)
            case .left: (0, delta)
            }
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: vertical, wheel2: horizontal, wheel3: 0
            )?.postMarked()
            remaining -= delta
            try await Task.sleep(for: .milliseconds(8))
        }
    }

    private func press(_ keyCode: CGKeyCode) {
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown)
            event?.flags = []
            event?.postMarked()
        }
    }

    private func click(at point: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .postMarked()
        }
    }
}

extension CGEvent {
    /// このアプリが送ったイベントにつける印。ユーザー自身の操作と見分けるのに使う
    static let syntheticMarker: Int64 = 0x5743_4150  // "WCAP"

    var isMarkedSynthetic: Bool {
        getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker
    }

    fileprivate func postMarked() {
        setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        post(tap: .cghidEventTap)
    }
}

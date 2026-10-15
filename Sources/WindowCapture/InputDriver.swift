import AppKit
import ApplicationServices

/// 対象ウィンドウへのスクロール・キー入力・クリックを合成イベントで送る。アクセシビリティ権限が必要。
struct InputDriver {
    let window: WindowInfo

    func perform(_ settings: LoopSettings) async throws {
        switch settings.action {
        case .scroll:
            let point = point(in: settings)
            try await moveCursor(to: point)
            let length = settings.scrollDirection.isVertical ? window.frame.height : window.frame.width
            try await scroll(settings.scrollDirection, distance: length * settings.scrollRatio)
        case .key:
            press(settings.key.keyCode)
        case .click:
            let point = point(in: settings)
            try await moveCursor(to: point)
            click(at: point)
        case .timer:
            break
        }
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

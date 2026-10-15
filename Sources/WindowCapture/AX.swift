import ApplicationServices
import CoreGraphics

/// アクセシビリティ API の薄いラッパー
enum AX {
    /// ScreenCaptureKit のウィンドウに対応する AX ウィンドウを、位置とサイズで探す。
    static func window(matching window: WindowInfo) -> AXUIElement? {
        windows(of: window.pid).first { element in
            guard let frame = frame(of: element) else { return false }
            return abs(frame.minX - window.frame.minX) < 2 && abs(frame.minY - window.frame.minY) < 2
                && abs(frame.width - window.frame.width) < 2 && abs(frame.height - window.frame.height) < 2
        }
    }

    /// 要素の画面上の位置とサイズ (左上原点のグローバル座標)
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = value(element, "AXPosition", type: .cgPoint, initial: CGPoint.zero),
              let size = value(element, "AXSize", type: .cgSize, initial: CGSize.zero)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        attribute(AXUIElementCreateApplication(pid), "AXWindows") ?? []
    }

    /// タイトル・説明・識別子のうち最初に見つかったもの
    static func label(of element: AXUIElement) -> String? {
        for name in ["AXTitle", "AXDescription", "AXIdentifier"] {
            if let text: String = attribute(element, name), !text.isEmpty { return text }
        }
        return nil
    }

    static func role(of element: AXUIElement) -> String? {
        attribute(element, "AXRole")
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, "AXChildren") ?? []
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func value<T: BitwiseCopyable>(_ element: AXUIElement, _ name: String, type: AXValueType, initial: T) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var result = initial
        return AXValueGetValue(value as! AXValue, type, &result) ? result : nil
    }
}

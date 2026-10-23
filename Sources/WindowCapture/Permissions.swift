import AppKit
import ApplicationServices

enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// .app バンドルとして起動しているか。素の実行ファイルだと権限はターミナルや Xcode 側に紐づいてしまう。
    static var isRunningFromAppBundle: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    static func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// 画面収録の許可はプロセス再起動後に反映されることがあるため、自分自身を起動し直す。
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}

import AppKit
import ScreenCaptureKit

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let appName: String
    /// アプリ本体のファイル名 (例: "iTerm.app")。表示名と違うことがあるので検索に使う
    let appFileName: String
    let pid: pid_t
    let frame: CGRect
    let isOnScreen: Bool
    let scWindow: SCWindow

    init?(_ window: SCWindow) {
        guard let app = window.owningApplication else { return nil }
        id = window.windowID
        title = window.title ?? ""
        appName = app.applicationName
        appFileName = NSRunningApplication(processIdentifier: app.processID)?.bundleURL?.lastPathComponent ?? ""
        pid = app.processID
        frame = window.frame
        isOnScreen = window.isOnScreen
        scWindow = window
    }

    var displayTitle: String { title.isEmpty ? "(無題)" : title }
    var sizeText: String { "\(Int(frame.width))×\(Int(frame.height))" }
    var appIcon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }
    var searchableTexts: [String] { [appName, appFileName, title] }
    /// アプリごとの設定 (切り出し範囲など) を保存するキー
    var appKey: String { appFileName.isEmpty ? appName : appFileName }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum WindowCatalog {
    /// キャプチャ対象になりうる通常ウィンドウを、画面上にあるものを先にして返す。
    static func fetch() async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.compactMap { window -> WindowInfo? in
            guard window.windowLayer == 0,
                  window.frame.width >= 50, window.frame.height >= 50,
                  let info = WindowInfo(window), info.pid != ownPID,
                  info.isOnScreen || !info.title.isEmpty
            else { return nil }
            return info
        }
        return windows.filter(\.isOnScreen) + windows.filter { !$0.isOnScreen }
    }
}

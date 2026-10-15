import AppKit

/// 調査用の隠しコマンド。アプリ本体の権限で動かすため LaunchServices 経由で起動する:
///   open -n ~/Applications/WindowCapture.app --args --dump-ax <アプリ名> <出力ファイル>
///   open -n ~/Applications/WindowCapture.app --args --detect-content <アプリ名> <出力ファイル>
enum DebugCommands {
    static func runIfRequested() {
        let args = CommandLine.arguments
        for (flag, command) in [("--dump-ax", dumpAccessibilityTree), ("--detect-content", detectContent)] {
            guard let index = args.firstIndex(of: flag), args.count > index + 2 else { continue }
            let output = command(args[index + 1])
            try? output.write(toFile: args[index + 2], atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    /// 指定アプリの各ウィンドウについて、中身として検出した矩形 (ウィンドウ左上原点) を書き出す。
    private static func detectContent(appName: String) -> String {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
            return "app not found: \(appName)\n"
        }
        return AX.windows(of: app.processIdentifier).compactMap { element -> String? in
            guard let frame = AX.frame(of: element) else { return nil }
            let rect = ContentAreaDetector.detect(windowElement: element, windowFrame: frame)
            return "window \(frame) -> content \(rect.map { "\($0)" } ?? "nil")"
        }.joined(separator: "\n") + "\n"
    }

    /// 指定アプリの全ウィンドウの AX ツリーを、役割・位置とサイズ・タイトルとともにテキストにする。
    private static func dumpAccessibilityTree(appName: String) -> String {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
            return "app not found: \(appName)\n"
        }
        var lines = ["trusted: \(AXIsProcessTrusted())", "pid: \(app.processIdentifier)"]
        var visited = 0

        func dump(_ element: AXUIElement, depth: Int) {
            visited += 1
            guard visited <= 2000, depth <= 20 else { return }
            let role = AX.role(of: element) ?? "?"
            let frame = AX.frame(of: element).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "(no frame)"
            let label = AX.label(of: element).map { " \"\($0.prefix(60))\"" } ?? ""
            lines.append(String(repeating: "  ", count: depth) + "\(role) \(frame)\(label)")
            for child in AX.children(of: element) {
                dump(child, depth: depth + 1)
            }
        }

        for window in AX.windows(of: app.processIdentifier) {
            dump(window, depth: 0)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// 動作確認用の起動オプション。指定したときは設定を保存しない。
///   --select-window <検索語>   起動時にそのウィンドウを選ぶ (サイドバーの検索と同じ一致方法)
///   --start-loop               選んだウィンドウで連続キャプチャを始める
///   --settings-json <JSON>     連続キャプチャの設定を上書きする (LoopSettings の JSON。省略した項目は既定値)
///   --save-dir <パス>          保存先を上書きする
///   --stop-after <秒>          連続キャプチャを始めてから指定秒数で止める
struct LaunchOptions {
    var selectWindow: String?
    var startLoop = false
    var stopAfter: Double?
    var settings: LoopSettings?
    var saveDirectory: URL?

    var overridesSettings: Bool { settings != nil || saveDirectory != nil }

    static let current = LaunchOptions(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
            return arguments[index + 1]
        }
        selectWindow = value(after: "--select-window")
        startLoop = arguments.contains("--start-loop")
        stopAfter = value(after: "--stop-after").flatMap(Double.init)
        settings = value(after: "--settings-json")
            .flatMap { try? JSONDecoder().decode(LoopSettings.self, from: Data($0.utf8)) }
        saveDirectory = value(after: "--save-dir").map { URL(filePath: $0, directoryHint: .isDirectory) }
    }
}

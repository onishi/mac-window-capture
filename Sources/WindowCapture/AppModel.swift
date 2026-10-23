import AppKit
import Observation

/// 画面下部のバーに出す、直前の操作の結果
struct StatusMessage: Equatable {
    enum Kind { case info, success, error }

    var text: String
    var kind: Kind = .info
    /// 「ファイルを開く」「フォルダを開く」の対象
    var output: CaptureOutput?
}

/// 撮影結果の場所
struct CaptureOutput: Equatable {
    /// 「ファイルを開く」で開くファイル (つなげた PNG、PDF、または撮った PNG 全部)
    var files: [URL]
    /// 保存したフォルダ
    var folder: URL
}

@Observable
final class AppModel {
    var windows: [WindowInfo] = []
    var searchText = ""
    var selectedWindowID: CGWindowID? {
        didSet {
            guard selectedWindowID != oldValue else { return }
            Task { await refreshPreview() }
        }
    }
    private(set) var preview: CGImage?
    private(set) var hasScreenRecording = Permissions.hasScreenRecording
    private(set) var hasAccessibility = Permissions.hasAccessibility
    /// 単発キャプチャや自動検出の結果。連続キャプチャの結果は session.phase で表す
    var status: StatusMessage?

    var settings: LoopSettings { didSet { persist(settings, forKey: Keys.settings) } }
    var includeShadow: Bool { didSet { persist(includeShadow, forKey: Keys.includeShadow) } }
    var copyToClipboard: Bool { didSet { persist(copyToClipboard, forKey: Keys.copyToClipboard) } }
    var saveDirectory: URL { didSet { persist(saveDirectory.path, forKey: Keys.saveDirectory) } }
    /// アプリごとの切り出し範囲。登録があるアプリは中身だけを撮る
    var cropsByApp: [String: CropInsets] { didSet { persist(cropsByApp, forKey: Keys.cropsByApp) } }

    let session = CaptureSession()
    @ObservationIgnored private let picker = WindowPicker()
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// 起動オプションで設定を上書きしたときは、保存済みの設定を書き換えない
    @ObservationIgnored private var persistsChanges = true
    @ObservationIgnored private let launchOptions = LaunchOptions.current

    private enum Keys {
        static let settings = "loopSettings"
        static let includeShadow = "includeShadow"
        static let copyToClipboard = "copyToClipboard"
        static let saveDirectory = "saveDirectory"
        static let cropsByApp = "cropsByApp"
    }

    init() {
        settings = defaults.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(LoopSettings.self, from: $0) } ?? LoopSettings()
        includeShadow = defaults.bool(forKey: Keys.includeShadow)
        copyToClipboard = defaults.object(forKey: Keys.copyToClipboard) as? Bool ?? true
        saveDirectory = defaults.string(forKey: Keys.saveDirectory)
            .map { URL(filePath: $0, directoryHint: .isDirectory) } ?? Exporter.defaultDirectory
        cropsByApp = defaults.data(forKey: Keys.cropsByApp)
            .flatMap { try? JSONDecoder().decode([String: CropInsets].self, from: $0) } ?? [:]

        if launchOptions.overridesSettings {
            persistsChanges = false
            launchOptions.settings.map { settings = $0 }
            launchOptions.saveDirectory.map { saveDirectory = $0 }
        }
    }

    // MARK: - 選択中のウィンドウ

    var filteredWindows: [WindowInfo] {
        windows.filter { WindowSearch.matches($0.searchableTexts, query: searchText) }
    }

    var selectedWindow: WindowInfo? {
        windows.first { $0.id == selectedWindowID }
    }

    /// 選択中のウィンドウのアプリに設定された切り出し範囲
    var currentCrop: CropInsets? {
        get { selectedWindow.flatMap { cropsByApp[$0.appKey] } }
        set {
            guard let window = selectedWindow else { return }
            cropsByApp[window.appKey] = newValue
        }
    }

    func refreshPermissions() {
        hasScreenRecording = Permissions.hasScreenRecording
        hasAccessibility = Permissions.hasAccessibility
    }

    func refreshWindows() async {
        guard hasScreenRecording else { return }
        do {
            windows = try await WindowCatalog.fetch()
            if selectedWindow == nil {
                selectedWindowID = nil
            }
            await refreshPreview()
        } catch {
            status = StatusMessage(text: "ウィンドウ一覧を取得できませんでした: \(error.localizedDescription)", kind: .error)
        }
    }

    /// 画面上のウィンドウをクリックして選択する。選ばれたら onPicked を呼ぶ。
    func pickWindowByClick(onPicked: @escaping () -> Void = {}) async {
        await refreshWindows()
        picker.start(candidates: windows) { [weak self] window in
            guard let self, let window else { return }
            select(window)
            NSApp.activate()
            onPicked()
        }
    }

    /// 選択を外して、ウィンドウを選ぶ前の状態に戻す
    func clearSelection() {
        guard !session.isRunning else { return }
        selectedWindowID = nil
        status = nil
    }

    func refreshPreview() async {
        guard let window = selectedWindow else {
            preview = nil
            return
        }
        // 操作位置や切り出し範囲の指定に使うので、影なし・切り出しなしで撮ってウィンドウ枠と座標を一致させる
        preview = try? await WindowCapturer.capture(window.scWindow, includeShadow: false).image
    }

    /// アクセシビリティ API で中身の領域を探して切り出し範囲にする。見つからなければウィンドウ全体を範囲にする。
    func detectContentArea() {
        guard let window = selectedWindow else { return }
        if let rect = ContentAreaDetector.detect(in: window) {
            currentCrop = CropInsets(rect: rect, in: window.frame.size)
            status = StatusMessage(text: "中身の領域を検出しました。プレビュー上をドラッグして調整できます。")
        } else {
            currentCrop = currentCrop ?? .zero
            status = StatusMessage(text: "中身の領域を検出できませんでした。プレビュー上をドラッグして範囲を指定してください。")
        }
    }

    // MARK: - キャプチャ

    var canCapture: Bool {
        selectedWindow != nil && hasScreenRecording && !session.isRunning
    }

    var canStartLoop: Bool {
        canCapture && (hasAccessibility || !settings.action.needsFocus)
    }

    /// 開始できない理由 (開始ボタンのヘルプに出す)
    var startBlocker: String? {
        if selectedWindow == nil { return "ウィンドウを選択してください" }
        if !hasScreenRecording { return "画面収録の許可が必要です" }
        if settings.action.needsFocus && !hasAccessibility { return "アクセシビリティの許可が必要です" }
        return nil
    }

    func captureSingle() async {
        guard let window = selectedWindow, canCapture else { return }
        do {
            let frame = try await WindowCapturer.capture(window.scWindow, includeShadow: includeShadow, crop: currentCrop)
            let url = try Exporter.singleFileURL(root: saveDirectory, label: window.appName)
            try Exporter.writePNG(frame.image, scale: frame.scale, to: url)
            if copyToClipboard {
                Exporter.copyToPasteboard(frame.image, scale: frame.scale)
            }
            status = StatusMessage(
                text: "保存しました\(copyToClipboard ? "（クリップボードにもコピー）" : ""): \(url.lastPathComponent)",
                kind: .success, output: CaptureOutput(files: [url], folder: saveDirectory)
            )
        } catch {
            status = StatusMessage(text: "キャプチャに失敗しました: \(error.localizedDescription)", kind: .error)
        }
    }

    func startLoop() {
        guard let window = selectedWindow, canStartLoop else { return }
        status = nil
        session.start(CaptureRequest(
            window: window,
            settings: settings,
            includeShadow: includeShadow,
            crop: currentCrop,
            saveRoot: saveDirectory
        )) { [weak self] in
            Task { await self?.refreshPreview() }
        }
    }

    // MARK: - 保存先

    func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url
        }
    }

    func openSaveDirectory() {
        try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveDirectory)
    }

    /// 結果のファイルを既定のアプリで開く。PNG が複数あれば 1 つのウィンドウにまとめて開く
    func open(_ output: CaptureOutput) {
        guard let first = output.files.first,
              let app = NSWorkspace.shared.urlForApplication(toOpen: first)
        else { return }
        NSWorkspace.shared.open(output.files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 結果を Finder で表示する。ファイルが 1 つならそれを選んだ状態で、複数ならフォルダを開く
    func revealFolder(_ output: CaptureOutput) {
        if output.files.count == 1 {
            NSWorkspace.shared.activateFileViewerSelecting(output.files)
        } else {
            NSWorkspace.shared.open(output.folder)
        }
    }

    // MARK: - 起動オプション

    /// 起動オプションで指定されたウィンドウを選び、必要なら連続キャプチャを始める (動作確認用)
    func applyLaunchOptions() async {
        guard let query = launchOptions.selectWindow,
              let window = windows.first(where: { WindowSearch.matches($0.searchableTexts, query: query) })
        else { return }
        select(window)
        if launchOptions.startLoop {
            try? await Task.sleep(for: .seconds(1))
            startLoop()
            if let seconds = launchOptions.stopAfter {
                try? await Task.sleep(for: .seconds(seconds))
                session.stop()
            }
        }
    }

    // MARK: - Private

    private func select(_ window: WindowInfo) {
        if !filteredWindows.contains(window) {
            searchText = ""
        }
        selectedWindowID = window.id
    }

    private func persist(_ value: some Encodable, forKey key: String) {
        guard persistsChanges else { return }
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private func persist(_ value: Bool, forKey key: String) {
        guard persistsChanges else { return }
        defaults.set(value, forKey: key)
    }

    private func persist(_ value: String, forKey key: String) {
        guard persistsChanges else { return }
        defaults.set(value, forKey: key)
    }
}

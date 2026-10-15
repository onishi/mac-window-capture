import AppKit
import Observation

/// 連続キャプチャ 1 回分の指定
struct CaptureRequest {
    var window: WindowInfo
    var settings: LoopSettings
    var includeShadow: Bool
    var crop: CropInsets?
    var saveRoot: URL
}

/// 連続キャプチャ 1 回分を実行する。
/// - 操作モード: 「操作 → 待機 → 画面が落ち着いたらキャプチャ」を繰り返す
/// - 一定間隔モード: 対象ウィンドウには触れず、開始時刻から n 秒ごとにキャプチャする
@Observable
final class CaptureSession {
    enum Phase: Equatable {
        case idle
        case running
        case finished(reason: String)
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var capturedCount = 0
    /// 一定間隔モードで、変化がなく保存しなかった回数
    private(set) var skippedCount = 0
    /// 結果の場所 (PNG を残すならフォルダ、PDF のみなら PDF ファイル)
    private(set) var outputURL: URL?
    private(set) var lastFrame: CGImage?

    /// 撮影後に PDF を作ったり 1 枚につなげたりしている間の進み具合 (していないときは nil)
    private(set) var finalizingText: String?
    /// つなげたときに、つなぎ目が見つからなかった箇所の注記
    private var stitchNote: String?

    private var task: Task<Void, Never>?
    private var stopReason: String?
    private var escapeMonitors: [Any] = []

    var isRunning: Bool { phase == .running }

    /// 実行中の連続キャプチャが対象ウィンドウを操作するか (Esc で止められるか)
    private(set) var operatesWindow = false

    func start(_ request: CaptureRequest, onFinish: @escaping () -> Void = {}) {
        guard !isRunning else { return }
        let settings = request.settings
        operatesWindow = settings.action.needsFocus
        phase = .running
        capturedCount = 0
        skippedCount = 0
        stopReason = nil
        stitchNote = nil
        outputURL = nil
        lastFrame = nil
        // 一定間隔モードは他のアプリを使いながら撮るので、他のアプリでの Esc では止めない
        installEscapeMonitors(global: settings.action.needsFocus)
        task = Task {
            await run(window: request.window, settings: settings, includeShadow: request.includeShadow, crop: request.crop, saveRoot: request.saveRoot)
            removeEscapeMonitors()
            onFinish()
        }
    }

    func stop(reason: String = "停止しました") {
        guard isRunning, stopReason == nil, finalizingText == nil else { return }
        stopReason = reason
        task?.cancel()
    }

    // MARK: - Private

    private func run(window: WindowInfo, settings: LoopSettings, includeShadow: Bool, crop: CropInsets?, saveRoot: URL) async {
        let driver = InputDriver(window: window)
        let originalCursor = InputDriver.cursorLocation
        defer {
            if settings.action.usesPoint { InputDriver.restoreCursor(to: originalCursor) }
        }

        let name = Exporter.sessionName(label: window.appName)
        // PDF のみのときは PNG を一時フォルダに置き、PDF を作ったら消す
        let directory: URL
        do {
            directory = try Exporter.makeDirectory(
                settings.effectiveOutput.keepsPNG
                    ? saveRoot.appending(path: name, directoryHint: .isDirectory)
                    : FileManager.default.temporaryDirectory.appending(path: "WindowCapture-\(UUID().uuidString)")
            )
        } catch {
            phase = .failed(message: error.localizedDescription)
            return
        }
        defer {
            if !settings.effectiveOutput.keepsPNG { try? FileManager.default.removeItem(at: directory) }
        }

        var pages: [URL] = []
        var scale: CGFloat = 2
        var reason = settings.isUnlimited
            ? "上限の \(LoopSettings.safetyLimit.formatted()) 枚に達しました"
            : "最大枚数に達しました"
        var failure: String?

        func save(_ frame: CapturedFrame) throws {
            let url = directory.appending(path: Exporter.frameFileName(index: pages.count + 1))
            try Exporter.writePNG(frame.image, scale: frame.scale, to: url)
            pages.append(url)
            scale = frame.scale
            capturedCount = pages.count
            lastFrame = frame.image
        }

        do {
            if settings.action == .timer {
                try await runTimer(window: window, settings: settings, includeShadow: includeShadow, crop: crop, save: save)
            } else {
                reason = try await runActions(
                    window: window, driver: driver, settings: settings, includeShadow: includeShadow, crop: crop, save: save
                ) ?? reason
            }
        } catch is CancellationError {
            reason = stopReason ?? "停止しました"
        } catch {
            // 途中で失敗しても、それまでに撮れた分は書き出す
            failure = "キャプチャに失敗しました: \(error.localizedDescription)"
        }

        let summary = "\(pages.count) 枚撮影" + (skippedCount > 0 ? " · 変化なし \(skippedCount) 回" : "")
        do {
            outputURL = try await finalize(
                pages: pages, scale: scale, settings: settings, directory: directory, saveRoot: saveRoot, name: name
            )
            let note = stitchNote.map { " · \($0)" } ?? ""
            phase = failure.map { .failed(message: "\($0) · \(summary)\(note)") }
                ?? .finished(reason: "\(reason) · \(summary)\(note)")
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// 操作モード。画面が変化しなくなって止めたときはその理由を返す。
    private func runActions(
        window: WindowInfo, driver: InputDriver, settings: LoopSettings,
        includeShadow: Bool, crop: CropInsets?, save: (CapturedFrame) throws -> Void
    ) async throws -> String? {
        driver.bringToFront()
        // 前面に出した直後に出る入力モードの表示などが消えるまで待つ
        try await Task.sleep(for: .seconds(1))
        var previous = try await WindowCapturer.captureStable(window.scWindow, includeShadow: includeShadow, crop: crop)
        try save(previous)

        while capturedCount < settings.effectiveMaxCount {
            if !driver.isFrontmost {
                driver.bringToFront()
                try await Task.sleep(for: .milliseconds(400))
            }
            try await driver.perform(settings)
            try await Task.sleep(for: .seconds(settings.interval))
            let frame = try await WindowCapturer.captureStable(window.scWindow, includeShadow: includeShadow, crop: crop)
            if settings.stopWhenUnchanged && FrameComparator.isSame(previous.fingerprint, frame.fingerprint) {
                return "画面が変化しなくなりました"
            }
            try save(frame)
            previous = frame
        }
        return nil
    }

    /// 一定間隔モード。開始時刻を基準に撮るので、キャプチャに時間がかかっても間隔がずれていかない。
    private func runTimer(
        window: WindowInfo, settings: LoopSettings,
        includeShadow: Bool, crop: CropInsets?, save: (CapturedFrame) throws -> Void
    ) async throws {
        let clock = ContinuousClock()
        let interval = Duration.seconds(settings.timerInterval)
        var next = clock.now
        var lastSaved: FrameFingerprint?

        while capturedCount < settings.effectiveMaxCount {
            try await Task.sleep(until: next, clock: clock)
            let frame = try await WindowCapturer.capture(window.scWindow, includeShadow: includeShadow, crop: crop)
            if settings.skipUnchanged, let lastSaved, FrameComparator.isSame(lastSaved, frame.fingerprint) {
                skippedCount += 1
            } else {
                try save(frame)
                lastSaved = frame.fingerprint
            }
            next += interval
            // キャプチャが間隔より長くかかったときは、遅れを取り戻そうと連続で撮らずに次の回から数え直す
            if next < clock.now { next = clock.now }
        }
    }

    /// PDF を作り、Finder で示す場所を返す (PNG を残すならフォルダ、PDF のみなら PDF ファイル)。
    /// 撮影を止めたあとの PDF 作成やつなぎ合わせは、停止ボタンでは中断しない (撮れた分を必ず書き出す)。
    /// Finder で示す場所 (PNG を残すならフォルダ、それ以外は作ったファイル) を返す。
    private func finalize(
        pages: [URL], scale: CGFloat, settings: LoopSettings, directory: URL, saveRoot: URL, name: String
    ) async throws -> URL? {
        let format = settings.effectiveOutput
        guard !pages.isEmpty else { return format.keepsPNG ? directory : nil }
        let total = pages.count
        defer { finalizingText = nil }

        if format == .stitched {
            let url = try Exporter.makeDirectory(saveRoot).appending(path: "\(name).png")
            finalizingText = "1 枚につなげています 0/\(total)"
            let result = try await Stitcher.stitch(
                pages: pages, direction: settings.stitchDirection, scale: scale, to: url
            ) { [weak self] done in
                Task { @MainActor in
                    if self?.finalizingText != nil { self?.finalizingText = "1 枚につなげています \(done)/\(total)" }
                }
            }
            stitchNote = result.unmatchedCount > 0 ? "つなぎ目不明 \(result.unmatchedCount) か所" : nil
            return url
        }

        guard format.makesPDF else { return directory }
        let pdfURL = format.keepsPNG
            ? directory.appending(path: "\(name).pdf")
            : try Exporter.makeDirectory(saveRoot).appending(path: "\(name).pdf")
        let ocr = settings.pdfOCR
        let describe: @Sendable (Int) -> String = { done in
            ocr ? "PDF 作成中 · 文字認識 \(done)/\(total)" : "PDF 作成中 \(done)/\(total)"
        }
        finalizingText = describe(0)
        try await Exporter.writePDF(pages: pages, scale: scale, to: pdfURL, ocr: ocr) { [weak self] done in
            Task { @MainActor in
                if self?.finalizingText != nil { self?.finalizingText = describe(done) }
            }
        }
        return format.keepsPNG ? directory : pdfURL
    }

    /// 停止のきっかけを監視する。
    /// - このアプリが前面のとき: Esc
    /// - 対象ウィンドウを操作するモードのとき: Esc に加え、ユーザー自身のキー入力・クリック・スクロール。
    ///   操作中に打った文字やクリックが対象ウィンドウに入ってしまうのを防ぐため、すぐ止める。
    ///   マウスを動かすだけでは対象は変わらない (操作のたびにカーソルを置き直す) ので止めない
    private func installEscapeMonitors(global: Bool) {
        let escapeKeyCode: UInt16 = 53
        if global, let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel],
            handler: { [weak self] event in
                guard event.cgEvent?.isMarkedSynthetic != true else { return }
                if event.type == .keyDown && event.keyCode == escapeKeyCode {
                    self?.stop()
                } else {
                    self?.stop(reason: "キーボードやマウスの操作があったため停止しました")
                }
            }
        ) {
            escapeMonitors.append(monitor)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == escapeKeyCode else { return event }
            self?.stop()
            return nil
        }) {
            escapeMonitors.append(local)
        }
    }

    private func removeEscapeMonitors() {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors.removeAll()
    }
}

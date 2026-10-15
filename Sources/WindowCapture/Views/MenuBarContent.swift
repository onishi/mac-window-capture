import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.session.isRunning {
            Text(model.session.finalizingText ?? "連続キャプチャ中: \(model.session.capturedCount) 枚")
            if model.session.skippedCount > 0 {
                Text("変化なしでスキップ: \(model.session.skippedCount) 回")
            }
            Button("停止") { model.session.stop() }
            Divider()
        }
        Button("Window Capture を開く") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("クリックでウィンドウを選択…") {
            Task {
                await model.pickWindowByClick {
                    openWindow(id: "main")
                }
            }
        }
        .disabled(!model.hasScreenRecording || model.session.isRunning)
        Divider()
        Button("終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if !Permissions.isRunningFromAppBundle {
                Label(
                    "swift run や Xcode から起動しているため、権限が起動元のアプリに紐づきます。scripts/build-app.sh でインストールした ~/Applications/WindowCapture.app を使ってください。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.orange.opacity(0.08))
                Divider()
            }
            if !model.hasScreenRecording || !model.hasAccessibility {
                PermissionBanner()
                Divider()
            }
            NavigationSplitView {
                WindowListView()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
            } detail: {
                DetailView()
                    .frame(minWidth: 460)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            model.refreshPermissions()
            await model.refreshWindows()
            await model.applyLaunchOptions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        // ウィンドウを開いている間だけ通常のアプリにして ⌘Tab と Dock に出す。閉じたらメニューバー常駐に戻す
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct PermissionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.hasScreenRecording {
                HStack {
                    Label("画面収録の許可が必要です (キャプチャに使用)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("許可を求める") { Permissions.requestScreenRecording() }
                    Button("設定を開く") { Permissions.openScreenRecordingSettings() }
                }
            }
            if !model.hasAccessibility {
                HStack {
                    Label("アクセシビリティの許可が必要です (スクロール・キー入力・クリックに使用)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("許可を求める") { Permissions.requestAccessibility() }
                    Button("設定を開く") { Permissions.openAccessibilitySettings() }
                }
            }
            HStack {
                Text("許可したあと反映されない場合は、アプリを再起動してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("再起動") { Permissions.relaunch() }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08))
    }
}

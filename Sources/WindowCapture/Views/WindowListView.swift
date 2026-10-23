import SwiftUI

struct WindowListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedWindowID) {
            Section("ウィンドウ") {
                ForEach(model.filteredWindows) { window in
                    WindowRow(window: window)
                        .tag(window.id)
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(model.session.isRunning)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "アプリ名・タイトルで検索")
        .overlay {
            if !model.hasScreenRecording {
                ContentUnavailableView("画面収録の許可が必要です", systemImage: "macwindow")
            } else if model.windows.isEmpty {
                ContentUnavailableView("ウィンドウがありません", systemImage: "macwindow")
            } else if model.filteredWindows.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refreshWindows() }
                } label: {
                    Label("一覧を更新", systemImage: "arrow.clockwise")
                }
                .help("ウィンドウ一覧を更新")
                .disabled(!model.hasScreenRecording)
            }
        }
    }
}

private struct WindowRow: View {
    let window: WindowInfo

    var body: some View {
        HStack(spacing: 10) {
            if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "macwindow")
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(window.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(window.appName) · \(window.sizeText)\(window.isOnScreen ? "" : " · 画面外")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .help("\(window.appName) — \(window.displayTitle)")
    }
}

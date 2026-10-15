import SwiftUI

/// 選択中のウィンドウのプレビュー・設定・操作ボタンを並べる右側のペイン
struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let window = model.selectedWindow {
            VSplitView {
                PreviewPane(window: window)
                    .frame(minHeight: 220, idealHeight: 320)
                SettingsForm()
                    .frame(minHeight: 200)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ActionBar()
            }
        } else {
            ContentUnavailableView {
                Label("ウィンドウを選択してください", systemImage: "macwindow.on.rectangle")
            } description: {
                Text("左の一覧から選ぶか、画面上のウィンドウを直接クリックして選べます。")
            } actions: {
                Button("クリックで選択") { Task { await model.pickWindowByClick() } }
                    .disabled(!model.hasScreenRecording)
            }
        }
    }
}

/// プレビューと、操作位置・切り出し範囲の指定
private struct PreviewPane: View {
    @Environment(AppModel.self) private var model
    let window: WindowInfo

    var body: some View {
        VStack(spacing: 8) {
            preview
            CropBar(window: window)
        }
        .padding(12)
        .navigationTitle(window.appName)
        .navigationSubtitle(window.displayTitle)
    }

    @ViewBuilder
    private var preview: some View {
        let size = window.frame.size
        // 実行中は最後に撮った画像を出して進み具合を見せる
        if model.session.isRunning, let frame = model.session.lastFrame {
            PreviewView(image: frame, point: nil, cropRect: nil, onSelectPoint: { _ in }, onSelectCrop: { _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PreviewView(
                image: model.preview,
                point: model.settings.action.usesPoint
                    ? CGPoint(x: model.settings.pointX, y: model.settings.pointY) : nil,
                cropRect: model.currentCrop?.rect(in: size).map { $0.normalized(in: size) },
                onSelectPoint: { point in
                    model.settings.pointX = point.x
                    model.settings.pointY = point.y
                },
                onSelectCrop: { rect in
                    model.currentCrop = CropInsets(rect: rect.denormalized(in: size), in: size)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(model.session.isRunning)
        }
    }
}

/// 切り出し (中身だけを撮る) の切り替えと範囲の表示
private struct CropBar: View {
    @Environment(AppModel.self) private var model
    let window: WindowInfo

    var body: some View {
        let isOn = Binding(
            get: { model.currentCrop != nil },
            set: { enabled in
                if enabled {
                    model.detectContentArea()
                } else {
                    model.currentCrop = nil
                }
            }
        )
        HStack(spacing: 8) {
            Toggle("中身だけ切り出す", isOn: isOn)
                .help("\(window.appName) の全ウィンドウで記憶します")
            if model.currentCrop != nil {
                Button("自動検出") { model.detectContentArea() }
                    .disabled(!model.hasAccessibility)
                    .help("ボタンやツールバーを除いた本文の領域を探します")
                Button("全体に戻す") { model.currentCrop = .zero }
            }
            Spacer()
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(window.sizeText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Button {
                Task { await model.refreshPreview() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("プレビューを更新")
        }
        .controlSize(.small)
        .disabled(model.session.isRunning)
    }

    private var hint: String {
        var parts: [String] = []
        if let rect = model.currentCrop?.rect(in: window.frame.size) {
            parts.append("\(Int(rect.width))×\(Int(rect.height)) を切り出し")
        }
        if model.currentCrop != nil { parts.append("ドラッグで範囲指定") }
        if model.settings.action.usesPoint { parts.append("クリックで操作位置") }
        return parts.joined(separator: " · ")
    }
}

extension CGRect {
    func normalized(in size: CGSize) -> CGRect {
        CGRect(x: minX / size.width, y: minY / size.height, width: width / size.width, height: height / size.height)
    }

    func denormalized(in size: CGSize) -> CGRect {
        CGRect(x: minX * size.width, y: minY * size.height, width: width * size.width, height: height * size.height)
    }
}

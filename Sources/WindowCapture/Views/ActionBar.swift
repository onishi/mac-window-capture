import SwiftUI

/// 画面下部に常に出る操作バー。左に状態、右に単発キャプチャと連続キャプチャの開始・停止
struct ActionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.session
        HStack(spacing: 12) {
            StatusView()
            Spacer(minLength: 8)
            if session.isRunning {
                Button {
                    session.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(session.finalizingText != nil)
                .keyboardShortcut(".", modifiers: .command)
                .help("連続キャプチャを止める (⌘.)")
            } else {
                Button {
                    Task { await model.captureSingle() }
                } label: {
                    Label("1 枚撮る", systemImage: "camera")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.canCapture)
                .help("今の画面を 1 枚保存する (⌘⇧C)")

                Button {
                    model.startLoop()
                } label: {
                    Label("連続キャプチャ開始", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canStartLoop)
                .help(model.startBlocker ?? "\(model.settings.action.label)で連続キャプチャを始める (⌘↩)")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// 実行中の進み具合、または直前の操作の結果
private struct StatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.session
        HStack(spacing: 6) {
            if session.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text(runningText)
                    .monospacedDigit()
            } else if let status = model.status {
                icon(for: status.kind)
                Text(status.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(status.text)
                if let output = status.output {
                    outputButtons(output)
                }
            } else {
                switch session.phase {
                case .idle, .running:
                    EmptyView()
                case .finished(let reason):
                    icon(for: .success)
                    Text(reason)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(reason)
                    if let output = session.output { outputButtons(output) }
                case .failed(let message):
                    icon(for: .error)
                    Text(message)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(message)
                    if let output = session.output { outputButtons(output) }
                }
            }
        }
        .font(.callout)
        .controlSize(.small)
    }

    private var runningText: String {
        let session = model.session
        if let finalizing = session.finalizingText { return finalizing }
        var text = "\(session.capturedCount) 枚撮影済み"
        if session.skippedCount > 0 {
            text += "（変化なし \(session.skippedCount) 回）"
        }
        return text + (session.operatesWindow ? " · Esc で停止" : "")
    }

    @ViewBuilder
    private func icon(for kind: StatusMessage.Kind) -> some View {
        switch kind {
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    /// 撮影後すぐに結果を見られるよう、文字付きのボタンで目立たせる
    private func outputButtons(_ output: CaptureOutput) -> some View {
        HStack(spacing: 8) {
            Button {
                model.open(output)
            } label: {
                Label(output.files.count > 1 ? "ファイルを開く (\(output.files.count))" : "ファイルを開く", systemImage: "doc.richtext")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: .command)
            .help("撮った結果を開く (⌘O)")

            Button {
                model.revealFolder(output)
            } label: {
                Label("フォルダを開く", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .help("Finder で表示 (⌘⇧O)")
        }
        .controlSize(.regular)
        .fixedSize()
        .padding(.leading, 6)
    }
}

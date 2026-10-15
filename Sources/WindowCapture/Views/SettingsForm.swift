import SwiftUI

/// 連続キャプチャの撮り方・終了条件と、保存の設定
struct SettingsForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            MethodSection(settings: $model.settings)
            StopConditionSection(settings: $model.settings)
            OutputSection()
        }
        .formStyle(.grouped)
        .disabled(model.session.isRunning)
    }
}

private struct MethodSection: View {
    @Binding var settings: LoopSettings

    var body: some View {
        Section {
            Picker("撮り方", selection: $settings.action) {
                ForEach(LoopAction.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)

            switch settings.action {
            case .scroll:
                Picker("方向", selection: $settings.scrollDirection) {
                    ForEach(ScrollDirection.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("1 回のスクロール量") {
                    HStack {
                        Slider(value: $settings.scrollRatio, in: 0.1...1.0, step: 0.05)
                        Text("\(Int(settings.scrollRatio * 100))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .help("ウィンドウの高さ (左右なら幅) に対する割合")
            case .key:
                Picker("送るキー", selection: $settings.key) {
                    ForEach(KeyPreset.allCases) { Text($0.label).tag($0) }
                }
            case .click, .timer:
                EmptyView()
            }

            if settings.action.usesPoint {
                LabeledContent("操作位置", value: "X \(Int(settings.pointX * 100))% · Y \(Int(settings.pointY * 100))%（プレビューをクリック）")
            }

            if settings.action == .timer {
                SecondsField(label: "撮影間隔", value: $settings.timerInterval, range: LoopSettings.timerIntervalRange)
            } else {
                SecondsField(label: "操作後の待ち時間", value: $settings.interval, range: LoopSettings.intervalRange)
            }
        } header: {
            Text("連続キャプチャ")
        } footer: {
            Text(settings.action.needsFocus
                 ? "実行中は対象ウィンドウが最前面になり、操作が自動で送られます。Esc で停止できます。"
                 : "対象ウィンドウには触れずに撮るので、他の作業を続けられます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StopConditionSection: View {
    @Binding var settings: LoopSettings

    var body: some View {
        Section("終了条件") {
            LabeledContent("最大枚数") {
                HStack(spacing: 8) {
                    if !settings.isUnlimited {
                        TextField("最大枚数", value: maxCount, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Stepper("最大枚数", value: maxCount, in: 1...9999)
                            .labelsHidden()
                    }
                    Toggle("無制限", isOn: $settings.isUnlimited)
                        .help("枚数で止めません (安全のため \(LoopSettings.safetyLimit.formatted()) 枚で停止します)")
                }
            }
            if settings.action == .timer {
                Toggle("変化がなければ保存しない", isOn: $settings.skipUnchanged)
            } else {
                Toggle("画面が変化しなくなったら停止", isOn: $settings.stopWhenUnchanged)
                    .help("スクロールやページ送りが最後まで進んだら自動で止めます")
            }
        }
    }

    private var maxCount: Binding<Int> {
        Binding(get: { settings.maxCount }, set: { settings.maxCount = min(max($0, 1), 9999) })
    }
}

private struct OutputSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("保存") {
            Picker("連続キャプチャの形式", selection: $model.settings.output) {
                ForEach(OutputFormat.available(for: model.settings.action)) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if model.settings.effectiveOutput == .stitched {
                Text("スクロールして撮った画像の重なりを取り除き、縦長 (左右のスクロールなら横長) の PNG 1 枚にします。ツールバーなどの固定部分は 1 回だけ入ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.settings.effectiveOutput.makesPDF {
                Toggle("PDF に文字認識 (OCR) のテキストを埋め込む", isOn: $model.settings.pdfOCR)
                    .help("日本語と英語を認識し、PDF 内の文字を検索・選択・コピーできるようにします。端末内で処理し、撮影後に時間がかかります")
            }
            LabeledContent("保存先") {
                HStack(spacing: 6) {
                    Text(model.saveDirectory.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("変更…") { model.chooseSaveDirectory() }
                    Button {
                        model.openSaveDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Finder で開く")
                }
            }
            Toggle("ウィンドウの影を含める", isOn: $model.includeShadow)
                .disabled(model.currentCrop != nil)
                .help(model.currentCrop != nil ? "中身だけ切り出すときは影を含めません" : "")
            Toggle("単発キャプチャをクリップボードにもコピー", isOn: $model.copyToClipboard)
        }
    }
}

/// 秒数を直接入力でき、ステッパーでも増減できる欄
private struct SecondsField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, value: clamped, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("秒")
                Stepper(label, value: clamped, in: range, step: value < 10 ? 0.5 : 5)
                    .labelsHidden()
            }
        }
    }

    private var clamped: Binding<Double> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

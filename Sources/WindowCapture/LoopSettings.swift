import CoreGraphics

enum LoopAction: String, CaseIterable, Identifiable, Codable {
    // timer は以前 "none" (待つだけ) として保存していたので rawValue を引き継ぐ
    case scroll, key, click, timer = "none"

    var id: Self { self }

    var label: String {
        switch self {
        case .scroll: "スクロール"
        case .key: "キー入力"
        case .click: "クリック"
        case .timer: "一定間隔"
        }
    }

    var symbol: String {
        switch self {
        case .scroll: "scroll"
        case .key: "keyboard"
        case .click: "cursorarrow.click"
        case .timer: "timer"
        }
    }

    /// 対象ウィンドウを最前面にしてから操作する必要があるか
    var needsFocus: Bool { self != .timer }
    /// ウィンドウ内の位置を指定する操作か
    var usesPoint: Bool { self == .scroll || self == .click }
}

nonisolated enum ScrollDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case down, up, right, left

    var id: Self { self }

    var label: String {
        switch self {
        case .down: "下"
        case .up: "上"
        case .right: "右"
        case .left: "左"
        }
    }

    var isVertical: Bool { self == .down || self == .up }
}

enum KeyPreset: String, CaseIterable, Identifiable, Codable {
    case pageDown, pageUp, space, rightArrow, leftArrow, downArrow, upArrow, returnKey

    var id: Self { self }

    var label: String {
        switch self {
        case .pageDown: "Page Down"
        case .pageUp: "Page Up"
        case .space: "Space"
        case .rightArrow: "→"
        case .leftArrow: "←"
        case .downArrow: "↓"
        case .upArrow: "↑"
        case .returnKey: "Return"
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .pageDown: 0x79
        case .pageUp: 0x74
        case .space: 0x31
        case .rightArrow: 0x7C
        case .leftArrow: 0x7B
        case .downArrow: 0x7D
        case .upArrow: 0x7E
        case .returnKey: 0x24
        }
    }
}

enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case png, stitched, pngAndPDF, pdf

    var id: Self { self }

    var label: String {
        switch self {
        case .png: "PNG"
        case .pdf: "PDF のみ"
        case .pngAndPDF: "PNG と PDF"
        case .stitched: "1 枚につなげる"
        }
    }

    /// 撮った 1 枚ずつの PNG を残すか
    var keepsPNG: Bool { self == .png || self == .pngAndPDF }
    var makesPDF: Bool { self == .pdf || self == .pngAndPDF }

    /// その撮り方で選べる形式。一定間隔はスクロールしないので、つなげる形式は選べない
    static func available(for action: LoopAction) -> [OutputFormat] {
        action == .timer ? allCases.filter { $0 != .stitched } : allCases
    }
}

struct LoopSettings: Codable, Equatable {
    var action: LoopAction = .scroll
    var scrollDirection: ScrollDirection = .down
    /// 1 回のスクロール量 (ウィンドウの高さ・幅に対する割合)
    var scrollRatio: Double = 0.8
    var key: KeyPreset = .pageDown
    /// 操作位置 (ウィンドウ左上を 0, 右下を 1 とする割合)
    var pointX: Double = 0.5
    var pointY: Double = 0.5
    /// 操作してからキャプチャを始めるまでの待ち時間 (秒)
    var interval: Double = 0.5
    /// 一定間隔モードの撮影間隔 (秒)
    var timerInterval: Double = 5
    /// 一定間隔モードで、前回保存した画像から変化がなければ保存しない
    var skipUnchanged = true
    var maxCount: Int = 30
    /// 枚数を制限しない。ただし暴走防止のため safetyLimit 枚で止める
    var isUnlimited = false
    var stopWhenUnchanged = true
    var output: OutputFormat = .png
    /// PDF を作るときに文字認識 (OCR) して、検索・選択できるテキストを埋め込む
    var pdfOCR = true

    static let safetyLimit = 10_000
    static let intervalRange: ClosedRange<Double> = 0.1...30
    static let timerIntervalRange: ClosedRange<Double> = 0.1...3600

    /// 1 枚につなげるときのスクロール量の上限。つなぎ目を探すため、前の画像と 30% 以上重なるようにする
    static let maxStitchScrollRatio = 0.7

    /// 実際に使うスクロール量の割合
    var effectiveScrollRatio: Double {
        effectiveOutput == .stitched ? min(scrollRatio, Self.maxStitchScrollRatio) : scrollRatio
    }

    /// 実際に使う出力形式 (撮り方で選べない形式が残っていたら PNG にする)
    var effectiveOutput: OutputFormat {
        OutputFormat.available(for: action).contains(output) ? output : .png
    }

    /// つなげるときに、どちらへスクロールしたものとして扱うか (キー入力やクリックは下へ進むものとする)
    var stitchDirection: ScrollDirection {
        action == .scroll ? scrollDirection : .down
    }

    /// 実際に止める枚数
    var effectiveMaxCount: Int { isUnlimited ? Self.safetyLimit : min(maxCount, Self.safetyLimit) }
}

extension LoopSettings {
    /// 保存済みの設定に無い項目 (後から追加した項目) は既定値で補う。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LoopSettings()
        action = try container.decodeIfPresent(LoopAction.self, forKey: .action) ?? defaults.action
        scrollDirection = try container.decodeIfPresent(ScrollDirection.self, forKey: .scrollDirection) ?? defaults.scrollDirection
        scrollRatio = try container.decodeIfPresent(Double.self, forKey: .scrollRatio) ?? defaults.scrollRatio
        key = try container.decodeIfPresent(KeyPreset.self, forKey: .key) ?? defaults.key
        pointX = try container.decodeIfPresent(Double.self, forKey: .pointX) ?? defaults.pointX
        pointY = try container.decodeIfPresent(Double.self, forKey: .pointY) ?? defaults.pointY
        interval = try container.decodeIfPresent(Double.self, forKey: .interval) ?? defaults.interval
        timerInterval = try container.decodeIfPresent(Double.self, forKey: .timerInterval) ?? defaults.timerInterval
        skipUnchanged = try container.decodeIfPresent(Bool.self, forKey: .skipUnchanged) ?? defaults.skipUnchanged
        maxCount = try container.decodeIfPresent(Int.self, forKey: .maxCount) ?? defaults.maxCount
        isUnlimited = try container.decodeIfPresent(Bool.self, forKey: .isUnlimited) ?? defaults.isUnlimited
        stopWhenUnchanged = try container.decodeIfPresent(Bool.self, forKey: .stopWhenUnchanged) ?? defaults.stopWhenUnchanged
        output = try container.decodeIfPresent(OutputFormat.self, forKey: .output) ?? defaults.output
        pdfOCR = try container.decodeIfPresent(Bool.self, forKey: .pdfOCR) ?? defaults.pdfOCR
    }
}

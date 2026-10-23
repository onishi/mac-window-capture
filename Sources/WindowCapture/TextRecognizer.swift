import CoreGraphics
import CoreText
import Foundation
import Vision

/// Vision で画像内の文字を認識し、PDF ページに透明なテキストとして重ねる。
/// 見た目は画像のままで、プレビュー.app などで検索・選択・コピーができるようになる。
nonisolated enum TextRecognizer {
    struct Line: Sendable {
        var text: String
        /// 画像に対する割合 (0...1)。Vision と同じく左下原点
        var box: CGRect
    }

    static let languages = ["ja-JP", "en-US"]

    /// 画像内の文字を行ごとに認識する。端末内で処理し、外部には送らない。
    static func recognize(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return Line(text: candidate.string, box: observation.boundingBox)
        }
    }

    /// 認識した行を、ページ (pageSize ポイント、左下原点) の同じ位置に透明な文字で描く。
    /// 選択範囲が画像上の文字と重なるよう、行の幅に合わせて文字を横に伸縮させる。
    static func drawInvisibleText(_ lines: [Line], pageSize: CGSize, in context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(
                x: line.box.minX * pageSize.width, y: line.box.minY * pageSize.height,
                width: line.box.width * pageSize.width, height: line.box.height * pageSize.height
            )
            guard rect.width > 0, rect.height > 0 else { continue }
            let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, rect.height * 0.85, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [.init(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }
            context.textMatrix = CGAffineTransform(scaleX: rect.width / width, y: 1)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }
}

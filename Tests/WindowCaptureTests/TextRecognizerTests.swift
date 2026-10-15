import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import WindowCapture

/// 白地に黒で文字を描いた画像
func makeTextImage(_ lines: [String], width: Int = 1600, height: Int = 900) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 72, nil)
    for (index, text) in lines.enumerated() {
        let attributed = NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 80, y: height - 160 - index * 140)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    return context.makeImage()!
}

@MainActor
@Suite struct TextRecognizerTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "WindowCaptureOCRTests-\(UUID().uuidString)")
    let lines = ["Window Capture 2026", "文字認識のテスト"]

    @Test func recognizesJapaneseAndEnglish() throws {
        let text = try TextRecognizer.recognize(makeTextImage(lines)).map(\.text).joined(separator: "\n")
        #expect(text.contains("Window Capture"))
        #expect(text.contains("文字認識"))
    }

    @Test func pdfWithOCRIsSearchable() async throws {
        let pdf = try await writePDF(ocr: true)
        let text = try #require(PDFDocument(url: pdf)?.string)
        #expect(text.contains("Window Capture"))
        #expect(text.contains("文字認識"))
    }

    @Test func pdfWithoutOCRHasNoText() async throws {
        let pdf = try await writePDF(ocr: false)
        let text = PDFDocument(url: pdf)?.string ?? ""
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func writePDF(ocr: Bool) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let png = root.appending(path: "0001.png")
        try Exporter.writePNG(makeTextImage(lines), scale: 2, to: png)
        let pdf = root.appending(path: "out-\(ocr).pdf")
        try await Exporter.writePDF(pages: [png], scale: 2, to: pdf, ocr: ocr)
        return pdf
    }
}

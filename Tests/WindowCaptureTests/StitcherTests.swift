import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import WindowCapture

/// 数値の並びをそのまま行ハッシュにしたフレーム (0 は余白の行)
private func frame(_ values: [Int]) -> Stitcher.FrameRows {
    Stitcher.FrameRows(hashes: values.map { UInt64($0) }, isBlank: values.map { $0 == 0 })
}

/// 長い文書 (行 y の値は 1000 + y) を、ヘッダー 2 行とフッター 1 行で挟んで offset から 40 行だけ見せたフレーム
private func window(at offset: Int) -> Stitcher.FrameRows {
    frame([9001, 9002] + (offset..<(offset + 40)).map { 1000 + $0 } + [9009])
}

@Suite struct StitcherPlanTests {
    @Test func joinsScrolledFramesWithFixedHeaderAndFooter() {
        let plan = Stitcher.plan([window(at: 0), window(at: 25), window(at: 50), window(at: 55)])
        #expect(plan.segments == [
            .init(frame: 0, rows: 0..<42),   // ヘッダー + 文書 0〜39
            .init(frame: 1, rows: 17..<42),  // 文書 40〜64
            .init(frame: 2, rows: 17..<42),  // 文書 65〜89
            .init(frame: 3, rows: 37..<42),  // 文書 90〜94 (最後は少しだけ進んだ)
            .init(frame: 3, rows: 42..<43),  // フッター
        ])
        #expect(plan.height == 2 + 95 + 1)
        #expect(plan.unmatchedCount == 0)
    }

    @Test func skipsIdenticalFrames() {
        let plan = Stitcher.plan([window(at: 0), window(at: 25), window(at: 25)])
        #expect(plan.height == 2 + 65 + 1)
    }

    @Test func appendsWholeContentWhenNoOverlap() {
        let plan = Stitcher.plan([window(at: 0), window(at: 100)])
        #expect(plan.unmatchedCount == 1)
        #expect(plan.height == 2 + 80 + 1)
    }

    @Test func blankRowsDoNotDecideShift() {
        // 余白の行 (0) が多くても、内容の行で正しいずれを求める
        let a = frame([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20])
        let b = frame([0, 0, 0, 0, 0, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25])
        #expect(Stitcher.offset(a, b, region: 0..<20) == 5)
    }

    @Test func singleFrameIsKeptAsIs() {
        let plan = Stitcher.plan([window(at: 0)])
        #expect(plan.segments == [.init(frame: 0, rows: 0..<43)])
    }
}

/// 疑似スクロール画像。各行の色を行番号から決めるので、どの行も別の内容になる
private enum FakeDocument {
    static let width = 300, viewport = 500, header = 40, footer = 30, scrollbar = 20

    static func color(row: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(row % 256) / 255, green: CGFloat(row / 256 % 256) / 255, blue: 0.5, alpha: 1)
    }

    /// 文書の rows 行目を上から並べ、必要ならヘッダーとフッター、フレームごとに違うスクロールバーを付ける
    static func image(documentRows: Range<Int>, withChrome: Bool, scrollbarSeed: Int?) -> CGImage {
        let height = documentRows.count + (withChrome ? header + footer : 0)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        func fillRow(_ y: Int, _ color: CGColor) {
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: height - 1 - y, width: width, height: 1))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 10, y: height - 1 - y, width: 30, height: 1))
        }
        var y = 0
        if withChrome { for i in 0..<header { fillRow(y, CGColor(gray: CGFloat(i) / 100, alpha: 1)); y += 1 } }
        for row in documentRows { fillRow(y, color(row: row)); y += 1 }
        if withChrome { for i in 0..<footer { fillRow(y, CGColor(gray: 0.5 + CGFloat(i) / 100, alpha: 1)); y += 1 } }
        if let seed = scrollbarSeed {
            context.setFillColor(CGColor(gray: CGFloat(seed % 5) / 5, alpha: 1))
            context.fill(CGRect(x: width - scrollbar, y: seed * 37 % (height - 60), width: scrollbar, height: 60))
        }
        return context.makeImage()!
    }

    static func frames(offsets: [Int], withScrollbar: Bool = true) -> [CGImage] {
        offsets.enumerated().map { index, offset in
            image(documentRows: offset..<(offset + viewport), withChrome: true, scrollbarSeed: withScrollbar ? index + 1 : nil)
        }
    }

    /// 期待するつなげた結果 (スクロールバーなし)
    static func expected(documentRows: Range<Int>) -> CGImage {
        image(documentRows: documentRows, withChrome: true, scrollbarSeed: nil)
    }
}

@MainActor
@Suite struct StitcherImageTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "WindowCaptureStitchTests-\(UUID().uuidString)")

    @Test func stitchesVerticalScroll() async throws {
        let offsets = [0, 400, 800, 1200, 1250, 1250]
        let output = try await stitch(FakeDocument.frames(offsets: offsets), direction: .down)
        try expectSameRows(output, FakeDocument.expected(documentRows: 0..<(1250 + FakeDocument.viewport)))
    }

    @Test func stitchesUpwardScrollInDocumentOrder() async throws {
        // 下から上へスクロールしたので、撮った順は文書の下から
        let offsets = [1200, 800, 400, 0]
        let output = try await stitch(FakeDocument.frames(offsets: offsets), direction: .up)
        try expectSameRows(output, FakeDocument.expected(documentRows: 0..<(1200 + FakeDocument.viewport)))
    }

    @Test func stitchesHorizontalScroll() async throws {
        // 縦スクロールの画像を左へ 90° 回して (下端が右端になる)、右へのスクロールに見立てる
        let frames = FakeDocument.frames(offsets: [0, 300, 600], withScrollbar: false).map { Stitcher.rotate($0, .counterClockwise) }
        let output = try await stitch(frames, direction: .right)
        let expected = Stitcher.rotate(FakeDocument.expected(documentRows: 0..<(600 + FakeDocument.viewport)), .counterClockwise)
        try expectSameRows(output, expected, ignoringScrollbar: false)
    }

    private func stitch(_ frames: [CGImage], direction: ScrollDirection) async throws -> CGImage {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pages = try frames.enumerated().map { index, image in
            let url = root.appending(path: Exporter.frameFileName(index: index + 1))
            try Exporter.writePNG(image, scale: 1, to: url)
            return url
        }
        let url = root.appending(path: "stitched-\(direction.rawValue).png")
        let result = try await Stitcher.stitch(pages: pages, direction: direction, scale: 1, to: url)
        #expect(result.unmatchedCount == 0)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// (スクロールバーの列を除いて) すべての行が同じか
    private func expectSameRows(_ actual: CGImage, _ expected: CGImage, ignoringScrollbar: Bool = true) throws {
        #expect(actual.width == expected.width)
        #expect(actual.height == expected.height)
        guard actual.height == expected.height else { return }
        let ignored = ignoringScrollbar ? FakeDocument.scrollbar : 0
        let a = Stitcher.rows(of: actual, ignoringTrailingColumns: ignored)
        let b = Stitcher.rows(of: expected, ignoringTrailingColumns: ignored)
        let mismatched = zip(a.hashes, b.hashes).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(mismatched.isEmpty, "一致しない行: \(mismatched.prefix(10))")
    }
}

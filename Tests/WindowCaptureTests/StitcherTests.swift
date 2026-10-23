import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import WindowCapture

/// 数値の並びから作ったフレーム。数値ごとに別の模様の行になる (0 は 1 色の余白の行)
private func frame(_ values: [Int]) -> Stitcher.FrameProfile {
    let width = 16
    let rows = values.flatMap { value -> [UInt8] in
        value == 0
            ? Array(repeating: 200, count: width)
            : (0..<width).map { UInt8((value * 31 + $0 * 17 + ($0 % 3) * value) % 256) }
    }
    return Stitcher.FrameProfile(width: width, values: rows)
}

/// 長い文書 (行 y の値は 1000 + y) を、ヘッダー 2 行とフッター 1 行で挟んで offset から 60 行だけ見せたフレーム
private func window(at offset: Int) -> Stitcher.FrameProfile {
    frame([9001, 9002] + (offset..<(offset + 60)).map { 1000 + $0 } + [9009])
}

@Suite struct StitcherPlanTests {
    @Test func joinsScrolledFramesWithFixedHeaderAndFooter() {
        let plan = Stitcher.plan([window(at: 0), window(at: 30), window(at: 60), window(at: 66)])
        // 重なりの真ん中でフレームを切り替える
        #expect(plan.segments == [
            .init(frame: 0, rows: 0..<47),   // ヘッダー + 文書 0〜44
            .init(frame: 1, rows: 17..<47),  // 文書 45〜74
            .init(frame: 2, rows: 17..<35),  // 文書 75〜92
            .init(frame: 3, rows: 29..<62),  // 文書 93〜125 (最後は少しだけ進んだ)
            .init(frame: 3, rows: 62..<63),  // フッター
        ])
        #expect(plan.height == 2 + 126 + 1)
        #expect(plan.unmatchedCount == 0)
    }

    @Test func skipsIdenticalFrames() {
        let plan = Stitcher.plan([window(at: 0), window(at: 30), window(at: 30)])
        #expect(plan.height == 2 + 90 + 1)
    }

    @Test func appendsWholeContentWhenNoOverlap() {
        let plan = Stitcher.plan([window(at: 0), window(at: 200)])
        #expect(plan.unmatchedCount == 1)
        #expect(plan.height == 2 + 120 + 1)
    }

    @Test func blankRowsDoNotDecideShift() {
        // 余白の行 (0) が多くても、内容の行で正しいずれを求める
        let a = frame(Array(repeating: 0, count: 20) + Array(11...40))
        let b = frame(Array(repeating: 0, count: 15) + Array(11...45))
        #expect(Stitcher.offset(a, b, region: 0..<50) == 5)
    }

    @Test func toleratesSlightDifferencesBetweenFrames() {
        // 文字のにじみ方が少し違う (各値が ±3 ずれる) フレームでもつなげる
        var b = window(at: 30)
        b.values = b.values.enumerated().map { index, value in UInt8(clamping: Int(value) + (index % 7 - 3)) }
        #expect(Stitcher.offset(window(at: 0), b, region: 2..<62) == 30)
    }

    @Test func ignoresPartlyChangingRows() {
        // 広告などで一部の行が変わっていても、残りが合えばつなげる
        var b = window(at: 30)
        for y in 10..<14 {
            for x in 0..<b.width { b.values[y * b.width + x] = UInt8((x * 97 + y * 13) % 256) }
        }
        #expect(Stitcher.offset(window(at: 0), b, region: 2..<62) == 30)
    }

    @Test func prefersExpectedShiftWhenAmbiguous() {
        // 同じ模様が 10 行おきに繰り返すと、ずれは 10 の倍数のどれでも合う
        let rows = frame((0..<60).map { 1 + $0 % 10 })
        #expect(Stitcher.offset(rows, rows, region: 0..<60, expectedShift: 30) == 30)
    }

    @Test func singleFrameIsKeptAsIs() {
        let plan = Stitcher.plan([window(at: 0)])
        #expect(plan.segments == [.init(frame: 0, rows: 0..<63)])
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

    /// (スクロールバーの列を除いて) すべての行のピクセルが同じか
    private func expectSameRows(_ actual: CGImage, _ expected: CGImage, ignoringScrollbar: Bool = true) throws {
        #expect(actual.width == expected.width)
        #expect(actual.height == expected.height)
        guard actual.width == expected.width, actual.height == expected.height else { return }
        let a = pixels(actual), b = pixels(expected)
        let usedBytes = (actual.width - (ignoringScrollbar ? FakeDocument.scrollbar : 0)) * 4
        let bytesPerRow = actual.width * 4
        let mismatched = (0..<actual.height).filter { y in
            a[(y * bytesPerRow)..<(y * bytesPerRow + usedBytes)] != b[(y * bytesPerRow)..<(y * bytesPerRow + usedBytes)]
        }
        #expect(mismatched.isEmpty, "一致しない行: \(mismatched.prefix(10))")
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}

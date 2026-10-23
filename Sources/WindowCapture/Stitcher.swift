import CoreGraphics
import Foundation
import ImageIO

/// スクロールしながら撮った画像を、重なりを除いて 1 枚につなげる。
///
/// アプリによっては (Chrome など)、スクロール位置が 1 ピクセル未満ずれて文字のにじみ方が変わるため、
/// 同じ内容でもピクセル単位では一致しない。そのため行をそのまま比べず、各行を横方向に縮めた明るさの並び
/// (プロファイル) を作り、差が最も小さくなるずれを探す。
///
/// 1. 各行のプロファイルを作る (スクロールバーや角丸の出る左右の端は除く)
/// 2. 隣り合う 2 枚で、同じ位置にほぼ同じ行が続く上端・下端を「固定部分」(タイトルバー・ツールバーなど) とみなす。
///    固定ヘッダーも描き直されるたびに少し違うことがあるので、行の 9 割がほぼ同じなら同じ行とする
/// 3. 固定部分を除いた範囲で、b の行 y と a の行 y + shift の差が最も小さい shift をスクロール量とする。
///    - 右側の広告だけ止まっているような、一部の列だけ動かないページがあるので、動いている列だけで比べる
///    - 広告やアニメーションで一部の行が変わっても引きずられないよう、行ごとの差には上限を設けて平均する
/// 4. 1 枚目の内容に、各フレームで新しく現れた行を足し、最後に下端の固定部分を付ける。
///    前のフレームから次のフレームへは重なりの真ん中で切り替える (フレームの端に出るウィンドウの角丸や、
///    ブラウザの左下のリンク表示などがつなぎ目に入らないように)
nonisolated enum Stitcher {
    /// 1 枚分の行プロファイル。行 y の明るさの並びは values[y * width ..< (y + 1) * width]
    struct FrameProfile: Sendable {
        var width: Int
        var values: [UInt8]

        var height: Int { width == 0 ? 0 : values.count / width }

        func value(row y: Int, column x: Int) -> Int { Int(values[y * width + x]) }

        /// 2 行の明るさの差の平均 (0...255)。columns を指定するとその列だけで比べる
        func difference(row y: Int, to other: FrameProfile, row otherY: Int, columns: [Int]? = nil) -> Double {
            var total = 0
            if let columns {
                for x in columns { total += abs(value(row: y, column: x) - other.value(row: otherY, column: x)) }
                return Double(total) / Double(max(1, columns.count))
            }
            for x in 0..<width { total += abs(value(row: y, column: x) - other.value(row: otherY, column: x)) }
            return Double(total) / Double(width)
        }

        /// 2 行で、明るさがほぼ同じ列の割合 (0...1)
        func similarity(row y: Int, to other: FrameProfile, row otherY: Int) -> Double {
            var same = 0
            for x in 0..<width where abs(value(row: y, column: x) - other.value(row: otherY, column: x)) <= 12 {
                same += 1
            }
            return Double(same) / Double(width)
        }

        /// 内容のある行か (余白のような 1 色の行はどのずれにも合ってしまうので、判定に使えない)
        func isTextured(row y: Int, columns: [Int]) -> Bool {
            var low = 255, high = 0
            for x in columns {
                let v = value(row: y, column: x)
                low = min(low, v)
                high = max(high, v)
            }
            return high - low > 24
        }
    }

    /// 出力画像を組み立てる部品。frame 番目の画像の rows の行を、上から順に並べる
    struct Segment: Equatable, Sendable {
        var frame: Int
        var rows: Range<Int>
    }

    struct Plan: Equatable, Sendable {
        var segments: [Segment]
        /// つなぎ目が見つからず、そのまま下に足したフレームの数
        var unmatchedCount: Int

        var height: Int { segments.reduce(0) { $0 + $1.rows.count } }
    }

    struct Result: Sendable {
        var pixelSize: CGSize
        var unmatchedCount: Int
    }

    /// 行プロファイルの横の要素数
    static let profileWidth = 160
    /// 同じ行とみなす、ほぼ同じ列の割合の下限 (固定部分の判定用)
    static let sameRowSimilarity = 0.9
    /// 固定部分の判定で、これだけ違う行が続いたら固定部分の終わりとする (1〜2 行のちらつきは許す)
    static let fixedEdgeBreakRows = 3
    /// 固定部分 (上端 + 下端) が占めてよい高さの割合の上限
    static let maxFixedRatio = 0.45
    /// 2 枚で動いていないとみなす列の、差の平均の上限
    static let staticColumnThreshold = 2.5
    /// 重なりとして認める、行の差の平均の上限
    static let matchThreshold = 6.0
    /// 平均するときの、行ごとの差の上限 (一部の行だけ大きく違っても引きずられないように)
    static let rowDifferenceCap = 40.0
    /// 重なりとして認める最低行数と、そのうち内容のある行の最低数
    static let minimumOverlapRows = 16
    static let minimumTexturedRows = 6
    /// 行プロファイルから除く左右の幅 (ポイント)。スクロールバーやウィンドウの角丸の分
    static let ignoredSidePoints = 20.0

    // MARK: - 組み立て計画 (ピクセルに触れない計算)

    /// expectedShift は 1 回のスクロールで進むはずの行数。判断がつかないときの手がかりにする
    static func plan(_ frames: [FrameProfile], expectedShift: Int? = nil) -> Plan {
        guard let first = frames.first else { return Plan(segments: [], unmatchedCount: 0) }
        let height = first.height
        guard frames.count > 1, frames.allSatisfy({ $0.height == height && $0.width == first.width }) else {
            return Plan(segments: [Segment(frame: 0, rows: 0..<height)], unmatchedCount: 0)
        }

        // 固定部分は全ペアで共通に使う (ペアごとに違うと、つなぎ目で行がずれるため)。
        // うまく判定できないペアに引きずられないよう中央値を使う。
        // 内容がまったく同じペア (最後まで進んで動かなくなった等) は判定に使わない
        let edges = (1..<frames.count).compactMap { fixedEdges(frames[$0 - 1], frames[$0]) }
        let top = median(edges.map(\.top))
        let bottom = median(edges.map(\.bottom))
        let contentEnd = height - bottom

        var segments = [Segment(frame: 0, rows: 0..<contentEnd)]
        var unmatched = 0
        for index in 1..<frames.count {
            let previous = frames[index - 1], current = frames[index]
            guard fixedEdges(previous, current) != nil else { continue }  // 同じ画面
            let shift: Int
            if let found = offset(previous, current, region: top..<contentEnd, expectedShift: expectedShift) {
                shift = found
            } else {
                shift = contentEnd - top
                unmatched += 1
            }
            guard shift > 0 else { continue }
            // 重なりの半分だけ前のフレームを短くし、そのぶん次のフレームを上から使う
            let overlap = contentEnd - top - shift
            let last = segments[segments.count - 1]
            let trim = min(overlap / 2, max(0, last.rows.count - 1))
            segments[segments.count - 1].rows = last.rows.lowerBound..<(last.rows.upperBound - trim)
            segments.append(Segment(frame: index, rows: (contentEnd - shift - trim)..<contentEnd))
        }
        if bottom > 0 {
            segments.append(Segment(frame: frames.count - 1, rows: contentEnd..<height))
        }
        return Plan(segments: segments, unmatchedCount: unmatched)
    }

    /// 2 枚で、同じ位置にほぼ同じ行が続く上端と下端の行数。2 枚がほぼ同じなら nil。
    static func fixedEdges(_ a: FrameProfile, _ b: FrameProfile) -> (top: Int, bottom: Int)? {
        let height = min(a.height, b.height)
        let same = (0..<height).map { a.similarity(row: $0, to: b, row: $0) >= sameRowSimilarity }
        guard same.contains(false) else { return nil }

        /// rows の順にたどり、違う行が fixedEdgeBreakRows 行続く手前までを固定部分とする
        func fixedLength(_ rows: some Sequence<Int>) -> Int {
            var length = 0, position = 0, misses = 0
            for y in rows {
                position += 1
                if same[y] {
                    length = position
                    misses = 0
                } else {
                    misses += 1
                    if misses >= fixedEdgeBreakRows { break }
                }
            }
            return length
        }
        let limit = Int(Double(height) * maxFixedRatio)
        let top = min(fixedLength(0..<height), limit)
        let bottom = min(fixedLength((top..<height).reversed()), limit - top)
        return (top, bottom)
    }

    private static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    /// region の範囲で、b の行 y が a の行 y + shift に最もよく合う shift (b が下にスクロールした行数)。
    /// 合うものが無ければ nil。
    static func offset(_ a: FrameProfile, _ b: FrameProfile, region: Range<Int>, expectedShift: Int? = nil) -> Int? {
        let maxShift = region.count - minimumOverlapRows
        guard maxShift >= 1 else { return nil }

        // 動いている列 (同じ位置で比べて違う列) だけで比べる。ほとんど動いていなければ全列を使う
        let moving = (0..<a.width).filter { x in
            var total = 0
            for y in region { total += abs(a.value(row: y, column: x) - b.value(row: y, column: x)) }
            return Double(total) / Double(region.count) >= staticColumnThreshold
        }
        let columns = moving.count >= a.width / 10 ? moving : Array(0..<a.width)

        // 内容のある行だけで比べる
        let textured = region.filter { b.isTextured(row: $0, columns: columns) }
        func score(_ shift: Int, stride step: Int) -> Double? {
            var total = 0.0, count = 0, index = 0
            for y in textured where y + shift < region.upperBound {
                if index % step == 0 {
                    total += min(a.difference(row: y + shift, to: b, row: y, columns: columns), rowDifferenceCap)
                    count += 1
                }
                index += 1
            }
            guard index >= minimumTexturedRows, count > 0 else { return nil }
            return total / Double(count)
        }

        guard textured.count >= minimumTexturedRows else {
            // 余白ばかりで判断できないときは、想定どおり進んだものとする
            return expectedShift.flatMap { (1...maxShift).contains($0) ? $0 : nil }
        }

        // 粗く全体を調べ、良さそうな候補だけを細かく調べ直す
        let coarse = (1...maxShift).compactMap { shift in score(shift, stride: 6).map { (shift, $0) } }
        let candidates = coarse.sorted { $0.1 < $1.1 }.prefix(8).map(\.0)
        var refined: [(shift: Int, score: Double)] = []
        for candidate in candidates {
            for shift in max(1, candidate - 2)...min(maxShift, candidate + 2) {
                if let value = score(shift, stride: 1) { refined.append((shift, value)) }
            }
        }
        guard let best = refined.min(by: { $0.score < $1.score }), best.score < matchThreshold else { return nil }

        // ほぼ同じくらい合う候補が複数あるときは、想定したスクロール量に近いものを選ぶ
        if let expectedShift {
            let close = refined.filter { $0.score <= best.score + 0.5 }
            return close.min { abs($0.shift - expectedShift) < abs($1.shift - expectedShift) }?.shift ?? best.shift
        }
        return best.shift
    }

    // MARK: - 画像の読み書き

    /// ファイルの画像を 1 枚につなげて PNG で書き出す。
    /// direction はスクロールした向き、expectedShiftPoints は 1 回に進むはずの量 (ポイント、分からなければ nil)。
    @concurrent
    static func stitch(
        pages: [URL], direction: ScrollDirection, scale: CGFloat, expectedShiftPoints: Double? = nil, to url: URL,
        progress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> Result {
        // 上・左へのスクロールは逆順に並べ、左右のスクロールは 90° 回して、どれも「下へのスクロール」として扱う
        let ordered = direction == .up || direction == .left ? pages.reversed() : pages
        let rotation: Rotation = direction.isVertical ? .none : .clockwise
        func load(_ page: URL) throws -> CGImage {
            guard let source = CGImageSourceCreateWithURL(page as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw ExportError.cannotRead(page) }
            return rotate(image, rotation)
        }

        let ignored = Int(ignoredSidePoints * scale)
        var frames: [FrameProfile] = []
        var width = 0
        for (index, page) in ordered.enumerated() {
            let image = try load(page)
            width = image.width
            frames.append(profile(of: image, ignoringSideColumns: ignored))
            progress(index + 1)
        }

        let plan = plan(frames, expectedShift: expectedShiftPoints.map { Int(($0 * scale).rounded()) })
        guard plan.height > 0,
              let context = CGContext(
                  data: nil, width: width, height: plan.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw ExportError.cannotWrite(url) }

        // CGContext は左下原点なので、上から積むために y を下から数える
        var top = 0
        var cache: (index: Int, image: CGImage)?
        for segment in plan.segments {
            let image: CGImage
            if let cache, cache.index == segment.frame {
                image = cache.image
            } else {
                image = try load(ordered[segment.frame])
                cache = (segment.frame, image)
            }
            let rect = CGRect(x: 0, y: segment.rows.lowerBound, width: image.width, height: segment.rows.count)
            if let part = image.cropping(to: rect) {
                context.draw(part, in: CGRect(x: 0, y: plan.height - top - segment.rows.count, width: image.width, height: segment.rows.count))
            }
            top += segment.rows.count
        }
        guard let stitched = context.makeImage() else { throw ExportError.cannotWrite(url) }
        let output = rotate(stitched, rotation.inverse)
        try Exporter.writePNG(output, scale: scale, to: url)
        return Result(pixelSize: CGSize(width: output.width, height: output.height), unmatchedCount: plan.unmatchedCount)
    }

    /// 各行を横方向に profileWidth 個まで縮めた明るさの並び。左右の端 ignoringSideColumns 列は含めない
    static func profile(of image: CGImage, ignoringSideColumns: Int = 0) -> FrameProfile {
        let side = min(ignoringSideColumns, max(0, (image.width - 1) / 2))
        let source = image.cropping(to: CGRect(x: side, y: 0, width: image.width - side * 2, height: image.height)) ?? image
        let width = min(profileWidth, source.width), height = source.height
        var values = [UInt8](repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { buffer in
            // 横だけを縮めて描くと、各要素はその範囲のピクセルの平均になる (ビットマップの先頭行が画像の上端)
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
            context?.interpolationQuality = .medium
            context?.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return FrameProfile(width: width, values: values)
    }

    // MARK: - 回転

    enum Rotation {
        case none, clockwise, counterClockwise

        var inverse: Rotation {
            switch self {
            case .none: .none
            case .clockwise: .counterClockwise
            case .counterClockwise: .clockwise
            }
        }
    }

    static func rotate(_ image: CGImage, _ rotation: Rotation) -> CGImage {
        guard rotation != .none,
              let context = CGContext(
                  data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        switch rotation {
        case .clockwise:
            context.translateBy(x: 0, y: w)
            context.rotate(by: -.pi / 2)
        case .counterClockwise:
            context.translateBy(x: h, y: 0)
            context.rotate(by: .pi / 2)
        case .none:
            break
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }
}

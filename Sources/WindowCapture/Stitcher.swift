import CoreGraphics
import Foundation
import ImageIO

/// スクロールしながら撮った画像を、重なりを除いて 1 枚につなげる。
///
/// 1. 各行のピクセルからハッシュを作る (スクロール中に出るスクロールバーで一致しなくならないよう、その列は除く)
/// 2. 隣り合う 2 枚で、同じ位置に同じ行が続く上端・下端を「固定部分」(タイトルバー・ツールバー・固定ヘッダーなど) とみなす
/// 3. 固定部分を除いた範囲で、同じ行がどれだけずれて現れるかを多数決で求め、それをスクロール量とする
/// 4. 1 枚目の上端からの内容に、各フレームで新しく現れた行を足し、最後に下端の固定部分を付ける
nonisolated enum Stitcher {
    /// 1 枚分の行ハッシュ
    struct FrameRows: Sendable {
        var hashes: [UInt64]
        /// 1 色だけの行 (余白など)。どこにでも一致してしまうので、ずれの多数決には使わない
        var isBlank: [Bool]
        var height: Int { hashes.count }
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

    /// 重なりとして認める、一致した行の最低割合
    static let minimumMatchRatio = 0.8
    /// 重なりとして認める最低行数
    static let minimumOverlapRows = 8
    /// 行ハッシュから除く右端の幅 (ポイント)。オーバーレイ表示のスクロールバーの分
    static let ignoredTrailingPoints = 20.0

    // MARK: - 組み立て計画 (ピクセルに触れない純粋な計算)

    static func plan(_ frames: [FrameRows]) -> Plan {
        guard let first = frames.first else { return Plan(segments: [], unmatchedCount: 0) }
        let height = first.height
        guard frames.count > 1, frames.allSatisfy({ $0.height == height }) else {
            return Plan(segments: [Segment(frame: 0, rows: 0..<height)], unmatchedCount: 0)
        }

        // 固定部分は全ペアで共通に使う (ペアごとに違うと、つなぎ目で行がずれるため)。
        // 内容がまったく同じペア (最後まで進んで動かなくなった等) は判定に使わない
        let pairs = (1..<frames.count).map { (frames[$0 - 1], frames[$0]) }
        let edges = pairs.compactMap { fixedEdges($0.0, $0.1) }
        let top = edges.map(\.top).min() ?? 0
        let bottom = edges.map(\.bottom).min() ?? 0
        let contentEnd = height - bottom

        var segments = [Segment(frame: 0, rows: 0..<contentEnd)]
        var unmatched = 0
        for index in 1..<frames.count {
            let previous = frames[index - 1], current = frames[index]
            guard fixedEdges(previous, current) != nil else { continue }  // 同じ画面
            let shift: Int
            if let found = offset(previous, current, region: top..<contentEnd) {
                shift = found
            } else {
                shift = contentEnd - top
                unmatched += 1
            }
            if shift > 0 {
                segments.append(Segment(frame: index, rows: (contentEnd - shift)..<contentEnd))
            }
        }
        if bottom > 0 {
            segments.append(Segment(frame: frames.count - 1, rows: contentEnd..<height))
        }
        return Plan(segments: segments, unmatchedCount: unmatched)
    }

    /// 2 枚で、同じ位置に同じ行が続く上端と下端の行数。2 枚がまったく同じなら nil。
    static func fixedEdges(_ a: FrameRows, _ b: FrameRows) -> (top: Int, bottom: Int)? {
        let height = min(a.height, b.height)
        var top = 0
        while top < height && a.hashes[top] == b.hashes[top] { top += 1 }
        guard top < height else { return nil }
        var bottom = 0
        while bottom < height - top && a.hashes[height - 1 - bottom] == b.hashes[height - 1 - bottom] { bottom += 1 }
        return (top, bottom)
    }

    /// region の範囲で、b の行 y が a の行 y + shift に一致するような shift (b が下にスクロールした量)。
    /// 見つからなければ nil。
    static func offset(_ a: FrameRows, _ b: FrameRows, region: Range<Int>) -> Int? {
        guard region.count > minimumOverlapRows else { return nil }

        // a の行ハッシュ → 位置。何度も出てくる行 (罫線など) は多数決を乱すので使わない
        var positions: [UInt64: [Int]] = [:]
        for y in region where !a.isBlank[y] {
            positions[a.hashes[y], default: []].append(y)
        }
        var votes: [Int: Int] = [:]
        for y in region where !b.isBlank[y] {
            guard let matches = positions[b.hashes[y]], matches.count <= 4 else { continue }
            for match in matches where match > y {
                votes[match - y, default: 0] += 1
            }
        }

        // 票の多い順に、重なり全体がちゃんと一致するかを確かめる
        for (shift, _) in votes.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(5) {
            let overlap = (region.lowerBound..<(region.upperBound - shift))
            guard overlap.count >= minimumOverlapRows else { continue }
            let matched = overlap.filter { b.hashes[$0] == a.hashes[$0 + shift] }.count
            if Double(matched) / Double(overlap.count) >= minimumMatchRatio {
                return shift
            }
        }
        return nil
    }

    // MARK: - 画像の読み書き

    /// ファイルの画像を 1 枚につなげて PNG で書き出す。direction はスクロールした向き。
    @concurrent
    static func stitch(
        pages: [URL], direction: ScrollDirection, scale: CGFloat, to url: URL,
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

        let ignored = Int(ignoredTrailingPoints * scale)
        var frames: [FrameRows] = []
        var width = 0
        for (index, page) in ordered.enumerated() {
            let image = try load(page)
            width = image.width
            // 縦スクロールのスクロールバーは右端に、横スクロールのスクロールバーは下端 (回転後は左端) に出る
            frames.append(direction.isVertical
                ? rows(of: image, ignoringTrailingColumns: ignored)
                : rows(of: image, ignoringLeadingColumns: ignored))
            progress(index + 1)
        }

        let plan = plan(frames)
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

    /// 各行のピクセルのハッシュ。左端 ignoringLeadingColumns 列と右端 ignoringTrailingColumns 列は含めない
    static func rows(of image: CGImage, ignoringLeadingColumns: Int = 0, ignoringTrailingColumns: Int = 0) -> FrameRows {
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let leading = min(ignoringLeadingColumns, width - 1)
        let trailing = min(ignoringTrailingColumns, width - 1 - leading)
        let usedStart = leading * 4
        let usedEnd = (width - trailing) * 4
        var hashes = [UInt64](repeating: 0, count: height)
        var isBlank = [Bool](repeating: true, count: height)
        pixels.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            // ビットマップの先頭行が画像の上端
            for y in 0..<height {
                let start = y * bytesPerRow
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a
                var blank = true
                for i in usedStart..<usedEnd {
                    let byte = bytes[start + i]
                    hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
                    if blank && byte != bytes[start + usedStart + i % 4] { blank = false }
                }
                hashes[y] = hash
                isBlank[y] = blank
            }
        }
        return FrameRows(hashes: hashes, isBlank: isBlank)
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

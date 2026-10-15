import CoreGraphics

/// フレーム比較用の縮小グレースケール画像
nonisolated struct FrameFingerprint: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

enum FrameComparator {
    nonisolated static let sampleWidth = 256
    /// この値を超える輝度差のあるピクセルを「変化した」とみなす
    nonisolated static let pixelThreshold = 16
    /// 変化したピクセルの割合がこれ未満なら同じ画面とみなす (カーソル点滅などを無視するため)
    nonisolated static let defaultTolerance = 0.002

    nonisolated static func fingerprint(of image: CGImage) -> FrameFingerprint {
        let width = min(sampleWidth, max(1, image.width))
        let height = max(1, Int((Double(image.height) * Double(width) / Double(max(1, image.width))).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return FrameFingerprint(width: width, height: height, pixels: pixels)
    }

    /// 変化したピクセルの割合 (0...1)。サイズが違えば 1。
    nonisolated static func changedRatio(_ a: FrameFingerprint, _ b: FrameFingerprint) -> Double {
        guard a.width == b.width, a.height == b.height, !a.pixels.isEmpty else { return 1 }
        var changed = 0
        for i in a.pixels.indices where abs(Int(a.pixels[i]) - Int(b.pixels[i])) > pixelThreshold {
            changed += 1
        }
        return Double(changed) / Double(a.pixels.count)
    }

    nonisolated static func isSame(
        _ a: FrameFingerprint,
        _ b: FrameFingerprint,
        tolerance: Double = defaultTolerance
    ) -> Bool {
        changedRatio(a, b) < tolerance
    }
}

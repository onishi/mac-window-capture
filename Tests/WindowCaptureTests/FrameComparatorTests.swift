import CoreGraphics
import Testing
@testable import WindowCapture

/// 白地に黒い横帯を描いた画像。帯の位置を変えるとスクロールした画面の代わりになる。
func makeImage(width: Int = 800, height: Int = 600, bandY: Int = 100, bandHeight: Int = 40, dot: CGRect? = nil) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: bandY, width: width, height: bandHeight))
    if let dot {
        context.fill(dot)
    }
    return context.makeImage()!
}

@Suite struct FrameComparatorTests {
    @Test func identicalImagesAreSame() {
        let a = FrameComparator.fingerprint(of: makeImage())
        let b = FrameComparator.fingerprint(of: makeImage())
        #expect(FrameComparator.changedRatio(a, b) == 0)
        #expect(FrameComparator.isSame(a, b))
    }

    @Test func scrolledImageIsDifferent() {
        let a = FrameComparator.fingerprint(of: makeImage(bandY: 100))
        let b = FrameComparator.fingerprint(of: makeImage(bandY: 140))
        #expect(!FrameComparator.isSame(a, b))
    }

    @Test func tinyChangeLikeBlinkingCaretIsIgnored() {
        let a = FrameComparator.fingerprint(of: makeImage())
        let b = FrameComparator.fingerprint(of: makeImage(dot: CGRect(x: 400, y: 400, width: 2, height: 16)))
        #expect(FrameComparator.isSame(a, b))
    }

    @Test func differentSizesAreDifferent() {
        let a = FrameComparator.fingerprint(of: makeImage(width: 800, height: 600))
        let b = FrameComparator.fingerprint(of: makeImage(width: 800, height: 700))
        #expect(FrameComparator.changedRatio(a, b) == 1)
    }

    @Test func fingerprintIsDownsampled() {
        let fingerprint = FrameComparator.fingerprint(of: makeImage(width: 2000, height: 1000))
        #expect(fingerprint.width == FrameComparator.sampleWidth)
        #expect(fingerprint.height == 128)
    }
}

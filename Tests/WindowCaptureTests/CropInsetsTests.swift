import CoreGraphics
import Testing
@testable import WindowCapture

@Suite struct CropInsetsTests {
    let window = CGSize(width: 800, height: 600)

    @Test func roundTripsBetweenRectAndInsets() {
        let rect = CGRect(x: 10, y: 52, width: 700, height: 500)
        let insets = CropInsets(rect: rect, in: window)
        #expect(insets == CropInsets(top: 52, left: 10, bottom: 48, right: 90))
        #expect(insets.rect(in: window) == rect)
    }

    @Test func keepsEdgeDistancesWhenWindowResizes() {
        // タイトルバー 52pt を削る設定は、ウィンドウが大きくなっても上から 52pt を削る
        let insets = CropInsets(top: 52, left: 0, bottom: 0, right: 0)
        #expect(insets.rect(in: CGSize(width: 1200, height: 900)) == CGRect(x: 0, y: 52, width: 1200, height: 848))
    }

    @Test func rectOutsideWindowIsClamped() {
        let insets = CropInsets(rect: CGRect(x: -20, y: -20, width: 2000, height: 100), in: window)
        #expect(insets == CropInsets(top: 0, left: 0, bottom: 520, right: 0))
    }

    @Test func overCroppingYieldsNil() {
        #expect(CropInsets(top: 400, left: 0, bottom: 300, right: 0).rect(in: window) == nil)
    }

    @Test func cropsImageInPixelsUsingScale() {
        let image = makeImage(width: 1600, height: 1200)  // 800×600pt @2x
        let cropped = CropInsets(top: 52, left: 10, bottom: 48, right: 90).crop(image, scale: 2)
        #expect(cropped.width == 1400)
        #expect(cropped.height == 1000)
    }

    @Test func zeroInsetsKeepWholeImage() {
        let image = makeImage(width: 1600, height: 1200)
        let cropped = CropInsets.zero.crop(image, scale: 2)
        #expect(cropped.width == 1600 && cropped.height == 1200)
    }
}

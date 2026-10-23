import CoreGraphics
import ScreenCaptureKit

struct CapturedFrame {
    let image: CGImage
    /// ポイントあたりのピクセル数 (Retina なら 2)
    let scale: CGFloat
    let fingerprint: FrameFingerprint
}

enum WindowCapturer {
    /// crop を指定すると中身だけを切り出す (切り出し時は影を含めない)。
    static func capture(_ window: SCWindow, includeShadow: Bool, crop: CropInsets? = nil) async throws -> CapturedFrame {
        let includeShadow = includeShadow && crop == nil
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)

        let config = SCStreamConfiguration()
        config.width = max(1, Int(info.contentRect.width * scale))
        config.height = max(1, Int(info.contentRect.height * scale))
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = !includeShadow
        config.showsCursor = false

        var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if let crop {
            image = crop.crop(image, scale: scale)
        }
        return CapturedFrame(image: image, scale: scale, fingerprint: FrameComparator.fingerprint(of: image))
    }

    /// 画面が落ち着く (連続 2 回のキャプチャがほぼ同じになる) まで撮り直す。
    /// スムーズスクロールやページ遷移のアニメーション中のフレームを避けるため。
    static func captureStable(
        _ window: SCWindow,
        includeShadow: Bool,
        crop: CropInsets?,
        pollInterval: Duration = .milliseconds(150),
        timeout: Duration = .seconds(3)
    ) async throws -> CapturedFrame {
        var latest = try await capture(window, includeShadow: includeShadow, crop: crop)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
            let next = try await capture(window, includeShadow: includeShadow, crop: crop)
            if FrameComparator.isSame(latest.fingerprint, next.fingerprint) {
                return next
            }
            latest = next
        }
        return latest
    }
}

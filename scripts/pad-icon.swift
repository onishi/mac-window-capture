// 元画像の角丸四角を macOS のアイコングリッド (1024px 中央の 824px 角丸四角) にぴったり合わせた 1024px の PNG を書き出す。
// 形が標準からずれていると macOS 26 以降は灰色の台座に載せて表示されるため、角丸四角はこちらで描き直し、元画像はその形で切り抜く。
// 使い方: swift scripts/pad-icon.swift <入力.png> <出力.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write(Data("usage: pad-icon.swift <input.png> <output.png>\n".utf8))
    exit(1)
}

let canvas = 1024
let artSize = 824.0

// 不透明部分 (アルファ > 200) の範囲を求める
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let reader = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
reader.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 200 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)

// 背景色は角丸四角の左端付近から拾う
let sampleIndex = ((minY + maxY) / 2 * width + minX + 40) * 4
let background = CGColor(
    srgbRed: CGFloat(pixels[sampleIndex]) / 255, green: CGFloat(pixels[sampleIndex + 1]) / 255,
    blue: CGFloat(pixels[sampleIndex + 2]) / 255, alpha: 1
)

// 角丸四角の短い辺が artSize より少し大きくなるよう拡大縮小し、中心をキャンバスの中心に合わせる (ビットマップ座標は上下反転)。
// 元画像の輪郭のぼけが切り抜きの縁に出ないよう、輪郭は切り抜きの外へ押し出す
let edgeMargin = 24.0
let scale = (artSize + edgeMargin) / min(bounds.width, bounds.height)
let center = CGPoint(x: bounds.midX, y: CGFloat(height) - bounds.midY)
let drawRect = CGRect(
    x: Double(canvas) / 2 - center.x * scale,
    y: Double(canvas) / 2 - center.y * scale,
    width: Double(width) * scale,
    height: Double(height) * scale
)
let inset = (Double(canvas) - artSize) / 2
let shape = CGPath(
    roundedRect: CGRect(x: inset, y: inset, width: artSize, height: artSize),
    cornerWidth: 185.4, cornerHeight: 185.4, transform: nil
)

let writer = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
writer.interpolationQuality = .high
writer.addPath(shape)
writer.clip()
writer.setFillColor(background)
writer.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
writer.draw(image, in: drawRect)

let output = URL(fileURLWithPath: args[2])
let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, writer.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print(String(format: "art bounds %.0f×%.0f → scaled ×%.3f", bounds.width, bounds.height, scale))

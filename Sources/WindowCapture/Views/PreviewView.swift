import SwiftUI

/// ウィンドウのプレビュー。座標はすべてプレビューに対する割合 (0...1)。
/// - クリック: 操作位置を指定する
/// - ドラッグ: 切り出し範囲を指定する (cropRect が nil でないとき)
struct PreviewView: View {
    let image: CGImage?
    let point: CGPoint?
    let cropRect: CGRect?
    let onSelectPoint: (CGPoint) -> Void
    let onSelectCrop: (CGRect) -> Void

    @State private var draggingRect: CGRect?

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        let size = proxy.size
                        ZStack {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    guard point != nil else { return }
                                    onSelectPoint(normalized(location, in: size))
                                }
                                .gesture(cropGesture(in: size))
                            if let rect = draggingRect ?? cropRect {
                                CropOverlay(rect: rect.scaled(to: size), size: size)
                                    .allowsHitTesting(false)
                            }
                            if let point {
                                Crosshair()
                                    .position(x: point.x * size.width, y: point.y * size.height)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .shadow(radius: 2)
        } else {
            ContentUnavailableView("プレビューなし", systemImage: "photo")
        }
    }

    private func cropGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard cropRect != nil else { return }
                let start = normalized(value.startLocation, in: size)
                let end = normalized(value.location, in: size)
                draggingRect = CGRect(
                    x: min(start.x, end.x), y: min(start.y, end.y),
                    width: abs(end.x - start.x), height: abs(end.y - start.y)
                )
            }
            .onEnded { _ in
                if let rect = draggingRect, rect.width > 0.01, rect.height > 0.01 {
                    onSelectCrop(rect)
                }
                draggingRect = nil
            }
    }

    private func normalized(_ location: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(location.x / size.width, 0), 1),
            y: min(max(location.y / size.height, 0), 1)
        )
    }
}

/// 切り出し範囲の外側を暗くし、範囲を枠で示す
private struct CropOverlay: View {
    let rect: CGRect
    let size: CGSize

    var body: some View {
        ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }
            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
            Rectangle()
                .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }
}

private struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.white, lineWidth: 4)
            Circle()
                .stroke(.red, lineWidth: 2)
            Circle()
                .fill(.red)
                .frame(width: 4, height: 4)
        }
        .frame(width: 22, height: 22)
    }
}

private extension CGRect {
    func scaled(to size: CGSize) -> CGRect {
        CGRect(x: minX * size.width, y: minY * size.height, width: width * size.width, height: height * size.height)
    }
}

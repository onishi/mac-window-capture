import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Exporter {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appending(path: "WindowCapture", directoryHint: .isDirectory)
    }

    /// 連続キャプチャ 1 回分の名前 (例: "2026-10-15 093012 Safari")。フォルダ名や PDF のファイル名に使う
    static func sessionName(label: String, date: Date = .now) -> String {
        "\(timestamp(date)) \(sanitize(label))"
    }

    static func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func singleFileURL(root: URL, label: String, date: Date = .now) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appending(path: "\(timestamp(date)) \(sanitize(label)).png")
    }

    static func frameFileName(index: Int) -> String {
        String(format: "%04d.png", index)
    }

    /// Retina でも等倍表示になるよう DPI を埋め込んで PNG を書き出す。
    nonisolated static func writePNG(_ image: CGImage, scale: CGFloat, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.cannotWrite(url)
        }
        let dpi = 72 * scale
        let properties = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.cannotWrite(url) }
    }

    /// PNG ファイル群を 1 ページ 1 枚の PDF にまとめる。ページサイズはポイント単位 (ピクセル ÷ scale)。
    /// ocr が true なら各ページの文字を認識し、透明なテキストとして重ねる (検索・選択できる PDF になる)。
    /// 文字認識は時間がかかるので、メインスレッドの外で動かす。progress には処理し終えたページ数を渡す。
    @concurrent
    nonisolated static func writePDF(
        pages: [URL], scale: CGFloat, to url: URL, ocr: Bool = false,
        progress: @Sendable (Int) -> Void = { _ in }
    ) async throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else { throw ExportError.cannotWrite(url) }
        for (index, page) in pages.enumerated() {
            guard let source = CGImageSourceCreateWithURL(page as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw ExportError.cannotRead(page) }
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            // 1 ページの認識に失敗しても PDF 全体は作る
            if ocr, let lines = try? TextRecognizer.recognize(image) {
                TextRecognizer.drawInvisibleText(lines, pageSize: box.size, in: context)
            }
            context.endPage()
            progress(index + 1)
        }
        context.closePDF()
    }

    static func copyToPasteboard(_ image: CGImage, scale: CGFloat) {
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let nsImage = NSImage(cgImage: image, size: size)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = nsImage.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    // MARK: - Private

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.string(from: date)
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Window" : cleaned
    }
}

enum ExportError: LocalizedError {
    case cannotWrite(URL)
    case cannotRead(URL)

    var errorDescription: String? {
        switch self {
        case .cannotWrite(let url): "書き込めませんでした: \(url.path)"
        case .cannotRead(let url): "読み込めませんでした: \(url.path)"
        }
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import WindowCapture

@MainActor
@Suite struct ExporterTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "WindowCaptureTests-\(UUID().uuidString)")

    @Test func sessionNameIsSanitized() {
        let name = Exporter.sessionName(label: "a/b:c", date: Date(timeIntervalSince1970: 0))
        #expect(name.hasSuffix(" a-b-c"))
        #expect(!name.contains("/"))
    }

    @Test func frameFileNamesSortInOrder() {
        #expect(Exporter.frameFileName(index: 1) == "0001.png")
        #expect(Exporter.frameFileName(index: 12) == "0012.png")
    }

    @Test func pngKeepsPixelSizeAndRecordsDPI() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "a.png")
        try Exporter.writePNG(makeImage(width: 400, height: 300), scale: 2, to: url)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 400)
        #expect(properties[kCGImagePropertyDPIWidth] as? Double == 144)
    }

    @Test func pdfHasOnePagePerImageInPoints() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = try (1...3).map { index in
            let url = root.appending(path: Exporter.frameFileName(index: index))
            try Exporter.writePNG(makeImage(width: 400, height: 300, bandY: index * 50), scale: 2, to: url)
            return url
        }
        let pdfURL = root.appending(path: "capture.pdf")
        try await Exporter.writePDF(pages: pages, scale: 2, to: pdfURL)

        let document = try #require(CGPDFDocument(pdfURL as CFURL))
        #expect(document.numberOfPages == 3)
        let box = try #require(document.page(at: 1)).getBoxRect(.mediaBox)
        #expect(box.size == CGSize(width: 200, height: 150))
    }
}

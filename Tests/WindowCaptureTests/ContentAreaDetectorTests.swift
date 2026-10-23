import CoreGraphics
import Testing
@testable import WindowCapture

@Suite struct ContentAreaDetectorTests {
    typealias Node = ContentAreaDetector.Node

    /// 実際の Kindle (740×1130) の AX ツリー。座標はウィンドウ左上原点
    let kindle: [Node] = [
        Node(role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 740, height: 1130), parent: nil, hasChildren: true),  // 0
        Node(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 740, height: 1130), parent: 0, hasChildren: true),      // 1
        Node(role: "AXButton", frame: CGRect(x: 8, y: 7, width: 12, height: 14), parent: 0, hasChildren: false),        // 閉じる
        Node(role: "AXButton", frame: CGRect(x: 48, y: 7, width: 12, height: 14), parent: 0, hasChildren: true),        // 拡大
        Node(role: "AXStaticText", frame: CGRect(x: 347, y: 5, width: 45, height: 16), parent: 0, hasChildren: false),  // タイトル
        Node(role: "AXButton", frame: CGRect(x: 13, y: 28, width: 40, height: 40), parent: 1, hasChildren: false),      // 本を閉じる
        Node(role: "AXButton", frame: CGRect(x: 53, y: 28, width: 40, height: 40), parent: 1, hasChildren: false),      // 目次
        Node(role: "AXHeading", frame: CGRect(x: 252, y: 41, width: 237, height: 13), parent: 1, hasChildren: false),   // 書名
        Node(role: "AXButton", frame: CGRect(x: 609, y: 28, width: 40, height: 40), parent: 1, hasChildren: false),     // 注釈
        Node(role: "AXButton", frame: CGRect(x: 649, y: 28, width: 40, height: 40), parent: 1, hasChildren: false),     // 読書の設定
        Node(role: "AXButton", frame: CGRect(x: 689, y: 28, width: 40, height: 40), parent: 1, hasChildren: false),     // その他
        Node(role: "AXButton", frame: CGRect(x: 689, y: 68, width: 40, height: 40), parent: 1, hasChildren: false),     // ブックマーク
        Node(role: "AXStaticText", frame: CGRect(x: 319, y: 1119, width: 103, height: 10), parent: 1, hasChildren: false), // 位置No.
        Node(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 740, height: 1130), parent: 1, hasChildren: true),      // 13 ReaderView
        Node(role: "AXGenericElement", frame: CGRect(x: 53, y: 0, width: 636, height: 1130), parent: 13, hasChildren: false), // 本文
        Node(role: "AXButton", frame: CGRect(x: 8, y: 546, width: 36, height: 36), parent: 1, hasChildren: false),      // 前のページ
    ]

    @Test func kindleBodyExcludesToolbarAndFooter() {
        let rect = ContentAreaDetector.contentArea(nodes: kindle, windowSize: CGSize(width: 740, height: 1130))
        #expect(rect == CGRect(x: 53, y: 68, width: 636, height: 1051))
    }

    @Test func webAreaIsPreferredAndItsOwnControlsAreIgnored() {
        let nodes = [
            Node(role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), parent: nil, hasChildren: true),
            Node(role: "AXToolbar", frame: CGRect(x: 0, y: 0, width: 1000, height: 80), parent: 0, hasChildren: true),
            Node(role: "AXWebArea", frame: CGRect(x: 0, y: 80, width: 1000, height: 720), parent: 0, hasChildren: true),
            // Web ページ内のボタンは中身の一部なので避けない
            Node(role: "AXButton", frame: CGRect(x: 400, y: 400, width: 100, height: 30), parent: 2, hasChildren: false),
        ]
        let rect = ContentAreaDetector.contentArea(nodes: nodes, windowSize: CGSize(width: 1000, height: 800))
        #expect(rect == CGRect(x: 0, y: 80, width: 1000, height: 720))
    }

    @Test func fallsBackToWindowMinusChrome() {
        let nodes = [
            Node(role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 600, height: 400), parent: nil, hasChildren: true),
            Node(role: "AXToolbar", frame: CGRect(x: 0, y: 0, width: 600, height: 52), parent: 0, hasChildren: true),
            Node(role: "AXGroup", frame: CGRect(x: 0, y: 52, width: 600, height: 348), parent: 0, hasChildren: true),
        ]
        let rect = ContentAreaDetector.contentArea(nodes: nodes, windowSize: CGSize(width: 600, height: 400))
        #expect(rect == CGRect(x: 0, y: 52, width: 600, height: 348))
    }

    @Test func largestEmptyRectAvoidsObstacleInMiddle() {
        let container = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rect = ContentAreaDetector.largestEmptyRect(in: container, avoiding: [CGRect(x: 0, y: 30, width: 100, height: 10)])
        #expect(rect == CGRect(x: 0, y: 40, width: 100, height: 60))
    }

    @Test func obstaclesOutsideContainerAreIgnored() {
        let container = CGRect(x: 50, y: 0, width: 100, height: 100)
        let rect = ContentAreaDetector.largestEmptyRect(in: container, avoiding: [CGRect(x: 0, y: 0, width: 50, height: 100)])
        #expect(rect == container)
    }
}

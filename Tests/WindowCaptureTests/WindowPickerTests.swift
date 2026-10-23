import CoreGraphics
import Testing
@testable import WindowCapture

@Suite struct WindowPickerTests {
    typealias ScreenWindow = WindowPicker.ScreenWindow

    // 手前から: 自分のウィンドウ、メニュー等 (layer 25)、エディタ、ブラウザ
    let windows = [
        ScreenWindow(id: 1, pid: 100, layer: 0, bounds: CGRect(x: 0, y: 0, width: 300, height: 300)),
        ScreenWindow(id: 2, pid: 200, layer: 25, bounds: CGRect(x: 400, y: 0, width: 50, height: 50)),
        ScreenWindow(id: 3, pid: 300, layer: 0, bounds: CGRect(x: 100, y: 100, width: 500, height: 400)),
        ScreenWindow(id: 4, pid: 400, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)),
    ]
    let candidates: Set<CGWindowID> = [3, 4]

    @Test func picksFrontmostWindowAtPoint() {
        #expect(WindowPicker.hitTest(CGPoint(x: 500, y: 200), in: windows, candidates: candidates, excludingPID: 100) == 3)
        #expect(WindowPicker.hitTest(CGPoint(x: 800, y: 600), in: windows, candidates: candidates, excludingPID: 100) == 4)
    }

    @Test func ownWindowsAreSeeThrough() {
        // 自分のウィンドウ (id 1) の下にあるエディタを選べる
        #expect(WindowPicker.hitTest(CGPoint(x: 150, y: 150), in: windows, candidates: candidates, excludingPID: 100) == 3)
    }

    @Test func nonNormalLayersAreSkipped() {
        #expect(WindowPicker.hitTest(CGPoint(x: 420, y: 20), in: windows, candidates: candidates, excludingPID: 100) == 4)
    }

    @Test func doesNotPickThroughNonCandidateWindow() {
        // 手前のウィンドウが候補外なら、その後ろを選んだりはしない
        #expect(WindowPicker.hitTest(CGPoint(x: 500, y: 200), in: windows, candidates: [4], excludingPID: 100) == nil)
    }

    @Test func emptyAreaPicksNothing() {
        #expect(WindowPicker.hitTest(CGPoint(x: 2000, y: 2000), in: windows, candidates: candidates, excludingPID: 100) == nil)
    }
}

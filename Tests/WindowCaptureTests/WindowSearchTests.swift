import Testing
@testable import WindowCapture

@Suite struct WindowSearchTests {
    let chrome = ["Google Chrome", "Google Chrome.app", "2026-10-15 朝会 - Hatenawiki"]
    let iterm = ["iTerm2", "iTerm.app", "◐ Mac ウィンドウ画像キャプチャアプリ"]

    @Test func emptyQueryMatchesEverything() {
        #expect(WindowSearch.matches(chrome, query: ""))
        #expect(WindowSearch.matches(chrome, query: "   "))
    }

    @Test func matchesAppNameCaseInsensitively() {
        #expect(WindowSearch.matches(chrome, query: "chrome"))
        #expect(!WindowSearch.matches(iterm, query: "chrome"))
    }

    @Test func matchesAppFileNameAndTitle() {
        #expect(WindowSearch.matches(iterm, query: "iterm.app"))
        #expect(WindowSearch.matches(chrome, query: "朝会"))
    }

    @Test func allTermsMustMatch() {
        #expect(WindowSearch.matches(chrome, query: "chrome 朝会"))
        #expect(!WindowSearch.matches(chrome, query: "chrome 夕会"))
    }

    @Test func ignoresWidthAndKanaDifferences() {
        #expect(WindowSearch.matches(chrome, query: "ＨＡＴＥＮＡ"))
        #expect(WindowSearch.matches(iterm, query: "きゃぷちゃ"))
        #expect(WindowSearch.matches(iterm, query: "ｷｬﾌﾟﾁｬ"))
    }
}

import Foundation
import Testing
@testable import WindowCapture

@MainActor
@Suite struct LoopSettingsTests {
    @Test func unlimitedStopsAtSafetyLimit() {
        var settings = LoopSettings()
        settings.maxCount = 30
        #expect(settings.effectiveMaxCount == 30)
        settings.isUnlimited = true
        #expect(settings.effectiveMaxCount == 10_000)
    }

    @Test func decodesSettingsSavedBeforeNewKeysWereAdded() throws {
        // isUnlimited を追加する前に保存された設定
        let json = #"{"action":"key","scrollDirection":"down","scrollRatio":0.8,"key":"rightArrow","pointX":0.5,"pointY":0.5,"interval":1.5,"maxCount":120,"stopWhenUnchanged":true,"output":"pdf"}"#
        let settings = try JSONDecoder().decode(LoopSettings.self, from: Data(json.utf8))
        #expect(settings.action == .key)
        #expect(settings.key == .rightArrow)
        #expect(settings.maxCount == 120)
        #expect(settings.output == .pdf)
        #expect(settings.isUnlimited == false)
    }

    @Test func roundTrips() throws {
        var settings = LoopSettings()
        settings.isUnlimited = true
        settings.interval = 2
        let decoded = try JSONDecoder().decode(LoopSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func oldWaitOnlyActionLoadsAsTimer() throws {
        // 「待つだけ」は "none" として保存されていた
        let json = #"{"action":"none","interval":2}"#
        let settings = try JSONDecoder().decode(LoopSettings.self, from: Data(json.utf8))
        #expect(settings.action == .timer)
        #expect(settings.timerInterval == 5)
        #expect(settings.skipUnchanged)
        #expect(!settings.action.needsFocus)
    }
}

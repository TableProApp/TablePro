import Foundation
@testable import TablePro
import Testing

@Suite("GeneralSettings.showRecentTables")
struct GeneralSettingsTests {
    @Test("Defaults to off")
    func defaultsOff() {
        #expect(GeneralSettings.default.showRecentTables == false)
        #expect(GeneralSettings().showRecentTables == false)
    }

    @Test("Decoding settings without the key keeps recent tables off")
    func decodesMissingKeyAsOff() throws {
        let json = Data(#"{"startupBehavior":"showWelcome"}"#.utf8)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: json)
        #expect(decoded.showRecentTables == false)
    }

    @Test("Round-trips when enabled")
    func roundTripsEnabled() throws {
        var settings = GeneralSettings()
        settings.showRecentTables = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)
        #expect(decoded.showRecentTables == true)
    }
}

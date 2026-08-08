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

@Suite("GeneralSettings.showObjectIcons")
struct GeneralSettingsObjectIconsTests {
    @Test("Defaults to on")
    func defaultsOn() {
        #expect(GeneralSettings.default.showObjectIcons == true)
        #expect(GeneralSettings().showObjectIcons == true)
    }

    @Test("Decoding settings saved before the key existed keeps icons on")
    func decodesMissingKeyAsOn() throws {
        let json = Data(#"{"startupBehavior":"showWelcome"}"#.utf8)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: json)
        #expect(decoded.showObjectIcons == true)
    }

    @Test("Round-trips when disabled")
    func roundTripsDisabled() throws {
        var settings = GeneralSettings()
        settings.showObjectIcons = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)
        #expect(decoded.showObjectIcons == false)
    }

    @Test("Icons and comments are independent")
    func independentFromComments() throws {
        var settings = GeneralSettings()
        settings.showObjectIcons = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)
        #expect(decoded.showObjectIcons == false)
        #expect(decoded.showObjectComments == true)
    }
}

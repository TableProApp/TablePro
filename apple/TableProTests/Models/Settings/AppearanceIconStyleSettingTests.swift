//
//  AppearanceIconStyleSettingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AppearanceIconStyleSettingTests {
    private func decode(_ json: String) throws -> AppearanceSettings {
        try JSONDecoder().decode(AppearanceSettings.self, from: Data(json.utf8))
    }

    @Test("Settings saved before the style existed decode to the standard style and keep their themes")
    func missingKeyIsStandard() throws {
        let settings = try decode(#"{"preferredLightThemeId":"light.one","preferredDarkThemeId":"dark.one"}"#)

        #expect(settings.objectIconStyle == .standard)
        #expect(settings.preferredLightThemeId == "light.one")
        #expect(settings.preferredDarkThemeId == "dark.one")
    }

    @Test("A fresh install draws the standard style")
    func defaultIsStandard() {
        #expect(AppearanceSettings.default.objectIconStyle == .standard)
        #expect(AppearanceSettings().objectIconStyle == .standard)
    }

    @Test("The colorful style survives a save and a load")
    func colorfulRoundTrips() throws {
        let saved = AppearanceSettings(objectIconStyle: .colorful)
        let data = try JSONEncoder().encode(saved)

        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: data) == saved)
    }

    @Test("A style a newer build invents reads as standard and drops nothing else")
    func unknownStyleIsStandard() throws {
        let settings = try decode(
            #"{"preferredLightThemeId":"light.one","preferredDarkThemeId":"dark.one","objectIconStyle":"neon"}"#
        )

        #expect(settings.objectIconStyle == .standard)
        #expect(settings.preferredLightThemeId == "light.one")
    }
}

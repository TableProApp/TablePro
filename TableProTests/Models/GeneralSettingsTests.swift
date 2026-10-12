import Foundation
@testable import TablePro
import Testing

struct AppLanguageTests {
    @Test("Includes Korean with its standard locale identifier and native name")
    func includesKorean() {
        #expect(AppLanguage(rawValue: "ko") == .korean)
        #expect(AppLanguage.korean.rawValue == "ko")
        #expect(AppLanguage.korean.displayName == "한국어")
        #expect(AppLanguage.allCases.contains(.korean))
    }

    @Test("Persists Korean in general settings")
    func persistsKorean() throws {
        let settings = GeneralSettings(language: .korean)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)

        #expect(decoded.language == .korean)
    }

    @Test("Includes French with its standard locale identifier and native name")
    func includesFrench() throws {
        #expect(AppLanguage(rawValue: "fr") == .french)
        #expect(AppLanguage.french.displayName == "Français")

        let data = try JSONEncoder().encode(GeneralSettings(language: .french))
        #expect(try JSONDecoder().decode(GeneralSettings.self, from: data).language == .french)
    }

    /// The picker writes the choice to `AppleLanguages`, and a language the catalog does not carry
    /// silently falls back to English, so offering one is a promise only the catalog can keep.
    @Test("Every language the picker offers is translated in the app's catalog")
    func everyOfferedLanguageShipsInTheCatalog() throws {
        let catalog = try Self.catalogStrings()
        let languageLabel = try #require(catalog["Language:"]?["localizations"] as? [String: Any])

        for language in AppLanguage.allCases where language != .system && language != .english {
            #expect(languageLabel[language.rawValue] != nil, "\(language.rawValue) is offered but not translated")
        }
    }

    private static func catalogStrings() throws -> [String: [String: Any]] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { throw CocoaError(.fileNoSuchFile) }
            directory = parent
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("TablePro/Resources/Localizable.xcstrings"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["strings"] as? [String: [String: Any]])
    }
}

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

struct GeneralSettingsWorkspaceRailTests {
    @Test("Defaults to on")
    func defaultsOn() {
        #expect(GeneralSettings.default.showWorkspaceRail)
        #expect(GeneralSettings().showWorkspaceRail)
    }

    @Test("Settings saved before the rail existed keep it on")
    func decodesMissingKeyAsOn() throws {
        let json = Data(#"{"startupBehavior":"showWelcome"}"#.utf8)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: json)
        #expect(decoded.showWorkspaceRail)
    }

    @Test("Round-trips when turned off")
    func roundTripsDisabled() throws {
        var settings = GeneralSettings()
        settings.showWorkspaceRail = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)
        #expect(!decoded.showWorkspaceRail)
    }
}

struct GeneralSettingsSystemContainersTests {
    @Test("Defaults to off")
    func defaultsOff() {
        #expect(GeneralSettings.default.showSystemContainers == false)
        #expect(GeneralSettings().showSystemContainers == false)
    }

    @Test("Settings saved before the key existed keep system databases hidden in the sidebar")
    func decodesMissingKeyAsOff() throws {
        let json = Data(#"{"startupBehavior":"showWelcome"}"#.utf8)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: json)
        #expect(decoded.showSystemContainers == false)
    }

    @Test("Round-trips when turned on")
    func roundTripsEnabled() throws {
        var settings = GeneralSettings()
        settings.showSystemContainers = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)
        #expect(decoded.showSystemContainers)
    }
}

struct GeneralSettingsUpdatePreferenceTests {
    @Test("A settings blob still carrying automaticallyCheckForUpdates decodes without it")
    func decodesBlobCarryingTheRemovedKey() throws {
        let json = Data(#"{"startupBehavior":"showWelcome","automaticallyCheckForUpdates":false,"showRecentTables":true,"queryTimeoutSeconds":90}"#.utf8)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: json)

        #expect(decoded.showRecentTables == true)
        #expect(decoded.queryTimeoutSeconds == 90)
    }

    @Test("The encoded blob no longer carries the key Sparkle owns")
    func doesNotEncodeTheUpdatePreference() throws {
        let data = try JSONEncoder().encode(GeneralSettings.default)
        let deserialized = try JSONSerialization.jsonObject(with: data)
        let object = try #require(deserialized as? [String: Any])

        #expect(object["automaticallyCheckForUpdates"] == nil)
    }
}

struct GeneralSettingsPartitionsTests {
    @Test("Defaults to on")
    func defaultsOn() {
        #expect(GeneralSettings.default.showPartitions == true)
        #expect(GeneralSettings().showPartitions == true)
    }

    @Test("Settings saved before the key existed keep partitions listed")
    func decodesMissingKeyAsOn() throws {
        let json = Data(#"{"startupBehavior":"showWelcome"}"#.utf8)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: json)
        #expect(decoded.showPartitions == true)
    }

    @Test("Round-trips when turned off")
    func roundTripsDisabled() throws {
        var settings = GeneralSettings()
        settings.showPartitions = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)
        #expect(decoded.showPartitions == false)
    }
}

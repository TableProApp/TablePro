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

struct GeneralSettingsBoolSettingTests {
    struct BoolSetting: Sendable, CustomTestStringConvertible {
        let key: String
        let defaultValue: Bool

        var testDescription: String { key }
    }

    static let settings = [
        BoolSetting(key: "shareAnalytics", defaultValue: true),
        BoolSetting(key: "showRecentTables", defaultValue: false),
        BoolSetting(key: "showObjectComments", defaultValue: true),
        BoolSetting(key: "showObjectIcons", defaultValue: true),
        BoolSetting(key: "showSystemContainers", defaultValue: false),
        BoolSetting(key: "showPartitions", defaultValue: true),
        BoolSetting(key: "showWorkspaceRail", defaultValue: true),
        BoolSetting(key: "showWelcomeVersionInfo", defaultValue: true)
    ]

    private static func encoded(_ settings: GeneralSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func decoded(_ object: [String: Any]) throws -> GeneralSettings {
        try JSONDecoder().decode(GeneralSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("Starts at its default", arguments: settings)
    func startsAtDefault(_ setting: BoolSetting) throws {
        #expect(try Self.encoded(.default)[setting.key] as? Bool == setting.defaultValue)
        #expect(try Self.encoded(GeneralSettings())[setting.key] as? Bool == setting.defaultValue)
    }

    @Test("Settings saved before the key existed decode to the default", arguments: settings)
    func decodesMissingKeyAsDefault(_ setting: BoolSetting) throws {
        let decoded = try Self.decoded(["startupBehavior": "showWelcome"])
        #expect(try Self.encoded(decoded)[setting.key] as? Bool == setting.defaultValue)
    }

    @Test("Round-trips the other value and leaves every other setting alone", arguments: settings)
    func roundTripsTheOtherValue(_ setting: BoolSetting) throws {
        var object = try Self.encoded(.default)
        object[setting.key] = !setting.defaultValue

        let roundTripped = try Self.encoded(Self.decoded(object))

        #expect(roundTripped[setting.key] as? Bool == !setting.defaultValue)
        for other in Self.settings where other.key != setting.key {
            #expect(roundTripped[other.key] as? Bool == other.defaultValue, "\(other.key)")
        }
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

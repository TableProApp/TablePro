import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

struct SyncSettingsTests {
    private static let everythingOn = SyncSettings(
        enabled: true,
        syncConnections: true,
        syncGroupsAndTags: true,
        syncSettings: true,
        syncPasswords: true,
        syncSSHProfiles: true,
        syncCredentialProfiles: true,
        syncTableFavorites: true,
        syncDatabaseFavorites: true,
        syncSQLFavorites: true,
        syncTableFolders: true
    )

    @Test("Turning Connections off turns Passwords off and leaves every other category")
    func connectionsOffClearsPasswords() {
        let result = Self.everythingOn.settingConnections(false)

        var expected = Self.everythingOn
        expected.syncConnections = false
        expected.syncPasswords = false
        #expect(result == expected)
        #expect(!result.syncsPasswords)
    }

    @Test("Turning Connections on keeps Passwords as it was", arguments: [true, false])
    func connectionsOnKeepsPasswords(passwords: Bool) {
        var settings = Self.everythingOn
        settings.syncConnections = false
        settings.syncPasswords = passwords
        settings.syncTableFolders = false

        let result = settings.settingConnections(true)

        var expected = settings
        expected.syncConnections = true
        #expect(result == expected)
    }

    @Test("Turning Connections off when it is already off changes nothing")
    func connectionsOffTwiceIsStable() {
        let once = SyncSettings.default.settingConnections(false)
        #expect(once.settingConnections(false) == once)
    }
}

struct SyncSettingsProviderTests {
    private static func decode(_ json: String) throws -> SyncSettings {
        try JSONDecoder().decode(SyncSettings.self, from: Data(json.utf8))
    }

    private static func encoded(_ settings: SyncSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Settings an earlier build wrote, with no provider, read iCloud from the switch", arguments: [true, false])
    func noProviderReadsTheSwitch(enabled: Bool) throws {
        let settings = try Self.decode(#"{"enabled": \#(enabled)}"#)
        #expect(settings.provider == (enabled ? .iCloud : .off))
    }

    @Test("TablePro Sync is written with iCloud off, so an earlier build reads iCloud off")
    func tableProSyncWritesICloudOff() throws {
        var settings = SyncSettings.default
        settings.provider = .tableproSync

        let json = try Self.encoded(settings)

        #expect(json["enabled"] as? Bool == false)
        #expect(json["provider"] as? String == "tablepro-sync")
        #expect(try JSONDecoder().decode(SyncSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test("iCloud turned on by an earlier build wins over a stored TablePro Sync")
    func switchWinsOverAStaleProvider() throws {
        let settings = try Self.decode(#"{"enabled": true, "provider": "tablepro-sync"}"#)
        #expect(settings.provider == .iCloud)
    }

    @Test("A provider with iCloud off stays, and a stale iCloud with the switch off reads Off")
    func providerWithTheSwitchOff() throws {
        #expect(try Self.decode(#"{"enabled": false, "provider": "tablepro-sync"}"#).provider == .tableproSync)
        #expect(try Self.decode(#"{"enabled": false, "provider": "icloud"}"#).provider == .off)
    }

    @Test("A provider this build does not know reads from the switch and keeps every other field")
    func unknownProviderReadsTheSwitch() throws {
        let settings = try Self.decode(#"{"enabled": false, "provider": "carrier-pigeon", "syncPasswords": true}"#)
        #expect(settings.provider == .off)
        #expect(settings.syncPasswords)
    }

    @Test("The iCloud switch moves the provider only between Off and iCloud")
    func switchFollowsTheProvider() {
        var settings = SyncSettings.default
        settings.provider = .tableproSync
        settings.enabled = false
        #expect(settings.provider == .tableproSync)

        settings.enabled = true
        #expect(settings.provider == .iCloud)

        settings.enabled = false
        #expect(settings.provider == .off)
    }
}

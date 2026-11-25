import Foundation
@testable import TableProMobile
import Testing

struct ManagedAppConfigurationTests {
    @Test("Each key core ADR 0055 gives iOS reads from its AppConfig type")
    func readsEveryKey() {
        let managed = ManagedAppConfiguration([
            "AccountServerURL": "https://tablepro.example.com",
            "AllowOtherAccountServers": false,
            "PersonalSyncProvider": ["tablepro-sync", "off"],
            "UsageDataAllowed": false,
            "ICloudSyncAllowed": false,
        ])

        #expect(managed.accountServerURL == "https://tablepro.example.com")
        #expect(managed.allowOtherAccountServers == false)
        #expect(managed.personalSyncProviders == [.tableProSync, .off])
        #expect(!managed.allowsUsageData)
        #expect(!managed.allowsICloudSync)
    }

    @Test("No configuration leaves every setting to the person")
    func absentIsUnmanaged() {
        let managed = ManagedAppConfiguration(nil)

        #expect(managed == .unmanaged)
        #expect(managed.allowsUsageData)
        #expect(managed.allowsICloudSync)
    }

    @Test("A value of another type counts as absent: a number is not a boolean, a string is not a list")
    func otherTypesAreAbsent() {
        let managed = ManagedAppConfiguration([
            "AccountServerURL": 42,
            "AllowOtherAccountServers": "false",
            "PersonalSyncProvider": "icloud",
            "UsageDataAllowed": NSNumber(value: 0),
            "ICloudSyncAllowed": [false],
        ])

        #expect(managed == .unmanaged)
    }

    @Test("An unknown provider is skipped, and an empty list allows none")
    func providers() {
        let mixed = ManagedAppConfiguration(["PersonalSyncProvider": ["icloud", "dropbox", "iCloud"]])
        let empty = ManagedAppConfiguration(["PersonalSyncProvider": [String]()])
        let notAllText = ManagedAppConfiguration(["PersonalSyncProvider": ["icloud", 1] as [Any]])

        #expect(mixed.personalSyncProviders == [.iCloud])
        #expect(empty.personalSyncProviders == [])
        #expect(notAllText.personalSyncProviders == nil)
    }

    @Test("True or absent booleans leave the person's own setting")
    func trueAllows() {
        let managed = ManagedAppConfiguration(["UsageDataAllowed": true, "ICloudSyncAllowed": true])

        #expect(managed.allowsUsageData)
        #expect(managed.allowsICloudSync)
    }

    @Test("It is read from the managed configuration key, where an MDM writes it")
    func readsTheManagedKey() throws {
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.Managed.\(UUID().uuidString)"))
        defaults.set(["ICloudSyncAllowed": false], forKey: "com.apple.configuration.managed")

        #expect(ManagedAppConfiguration.current(defaults: defaults).iCloudSyncAllowed == false)
    }
}

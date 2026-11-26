import Foundation
import TableProFFI
@testable import TableProMobile
import Testing

struct ManagedAppConfigurationTests {
    @Test("Each key core ADR 0055 gives iOS reads from its AppConfig type and reaches the core as read")
    func readsEveryKey() {
        let managed = ManagedAppConfiguration([
            "AccountServerURL": "https://tablepro.example.com",
            "AllowOtherAccountServers": false,
            "PersonalSyncProvider": ["tablepro-sync", "off"],
            "UsageDataAllowed": false,
            "ICloudSyncAllowed": false,
        ])

        #expect(managed.coreArgument == .read(values: ManagedPolicyValues(
            accountServerUrl: "https://tablepro.example.com",
            allowOtherAccountServers: false,
            personalSyncProvider: ["tablepro-sync", "off"],
            usageDataAllowed: false,
            pluginCatalogAllowed: nil,
            updateChecksAllowed: nil,
            icloudSyncAllowed: false
        )))
        #expect(!managed.allowsUsageData)
        #expect(!managed.allowsICloudSync)
    }

    @Test("No configuration leaves every setting to the person")
    func absentIsUnmanaged() {
        let managed = ManagedAppConfiguration(nil)

        #expect(managed == .unmanaged)
        #expect(managed.allowsUsageData)
        #expect(managed.allowsICloudSync)
        #expect(!managed.locksICloudSync)
        #expect(managed.settledICloudSync(true))
        #expect(!managed.settledICloudSync(false))
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

    @Test("A list entry that is not a string is left out, and the core skips a name it does not know")
    func listEntries() {
        let mixed = ManagedAppConfiguration(["PersonalSyncProvider": ["icloud", 1, "dropbox"] as [Any]])

        #expect(mixed.personalSyncProvider == ["icloud", "dropbox"])
        #expect(mixed.allowsICloudSync)
        #expect(mixed.locksICloudSync)
    }

    @Test("PersonalSyncProvider forces iCloud on or keeps it off, by the core's rule")
    func providerListSettlesICloud() {
        let forced = ManagedAppConfiguration(personalSyncProvider: ["icloud"])
        let off = ManagedAppConfiguration(personalSyncProvider: ["off"])
        let either = ManagedAppConfiguration(personalSyncProvider: ["off", "icloud"])
        let none = ManagedAppConfiguration(personalSyncProvider: [])

        #expect(forced.settledICloudSync(false) && forced.locksICloudSync)
        #expect(!off.settledICloudSync(true) && off.locksICloudSync && !off.allowsICloudSync)
        #expect(either.settledICloudSync(true) && !either.settledICloudSync(false) && !either.locksICloudSync)
        #expect(!none.settledICloudSync(true) && none.locksICloudSync)
    }

    @Test("ICloudSyncAllowed=false takes iCloud away even where the list names it")
    func iCloudSyncAllowedWins() {
        let managed = ManagedAppConfiguration(personalSyncProvider: ["icloud"], iCloudSyncAllowed: false)

        #expect(!managed.allowsICloudSync)
        #expect(!managed.settledICloudSync(true))
    }

    @Test("It is read from the managed configuration key, where an MDM writes it")
    func readsTheManagedKey() throws {
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.Managed.\(UUID().uuidString)"))
        defaults.set(["ICloudSyncAllowed": false], forKey: "com.apple.configuration.managed")

        #expect(ManagedAppConfiguration.current(defaults: defaults).iCloudSyncAllowed == false)
    }
}

import Foundation
import os
import TableProFFI

// The keys an MDM sets for this app as managed app configuration (core/docs/decisions/0055-managed-policies-for-the-sync-
// provider-and-tablepro-app-traffic.md). The raw values go to the core, which applies them by the rule every app shares.
// Absent, or of another type, a key leaves the person's own setting.
nonisolated struct ManagedAppConfiguration: Equatable, Sendable {
    static let defaultsKey = "com.apple.configuration.managed"
    static let offeredProviders: [SyncProviderTag] = [.off, .icloud, .tableproSync]

    private static let logger = Logger(subsystem: "com.TablePro", category: "ManagedAppConfiguration")

    var accountServerURL: String?
    var allowOtherAccountServers: Bool?
    var personalSyncProvider: [String]?
    var usageDataAllowed: Bool?
    var iCloudSyncAllowed: Bool?

    static let unmanaged = ManagedAppConfiguration()

    // Only an MDM writes this dictionary: the app has no code that sets it.
    static func current(defaults: UserDefaults = .standard) -> ManagedAppConfiguration {
        ManagedAppConfiguration(defaults.dictionary(forKey: defaultsKey))
    }

    init(
        accountServerURL: String? = nil,
        allowOtherAccountServers: Bool? = nil,
        personalSyncProvider: [String]? = nil,
        usageDataAllowed: Bool? = nil,
        iCloudSyncAllowed: Bool? = nil
    ) {
        self.accountServerURL = accountServerURL
        self.allowOtherAccountServers = allowOtherAccountServers
        self.personalSyncProvider = personalSyncProvider
        self.usageDataAllowed = usageDataAllowed
        self.iCloudSyncAllowed = iCloudSyncAllowed
    }

    init(_ values: [String: Any]?) {
        let values = values ?? [:]
        self.init(
            accountServerURL: Self.string(values, "AccountServerURL"),
            allowOtherAccountServers: Self.bool(values, "AllowOtherAccountServers"),
            personalSyncProvider: Self.strings(values, "PersonalSyncProvider"),
            usageDataAllowed: Self.bool(values, "UsageDataAllowed"),
            iCloudSyncAllowed: Self.bool(values, "ICloudSyncAllowed")
        )
    }

    // iOS has no plugin catalog and no update checks of its own, so it reads neither key.
    var coreArgument: ManagedPolicyArg {
        .read(values: ManagedPolicyValues(
            accountServerUrl: accountServerURL,
            allowOtherAccountServers: allowOtherAccountServers,
            personalSyncProvider: personalSyncProvider,
            usageDataAllowed: usageDataAllowed,
            pluginCatalogAllowed: nil,
            updateChecksAllowed: nil,
            icloudSyncAllowed: iCloudSyncAllowed
        ))
    }

    // A boolean that is true or absent leaves the person's own setting.
    var allowsUsageData: Bool {
        usageDataAllowed != false
    }

    // PersonalSyncProvider and ICloudSyncAllowed together, as the core reads them.
    var syncChoices: PersonalSyncChoices {
        personalSyncChoices(policy: coreArgument, offered: Self.offeredProviders)
    }

    var allowsICloudSync: Bool {
        syncChoices.providers.contains(.icloud)
    }

    var allowsTableProSync: Bool {
        syncChoices.providers.contains(.tableproSync)
    }

    // One choice or none: the provider is the organization's.
    var locksSyncProvider: Bool {
        syncChoices.locked
    }

    // The first run's iCloud question is the person's only while both iCloud and Off are theirs to pick.
    var locksICloudSync: Bool {
        let providers = syncChoices.providers
        return !(providers.contains(.icloud) && providers.contains(.off))
    }

    // The provider the values leave this device on, by the Mac's rule (SyncProviderPolicy.settledProvider). A forced
    // iCloud is taken as the person would pick it, and one taken away goes off. A move waits for the person: a forced
    // TablePro Sync leaves a device that is not on it off until the upload they confirm has run, and a forced iCloud
    // leaves one on TablePro Sync where it is until they confirm the move back (core ADRs 0054 and 0055).
    func settledProvider(_ chosen: SyncProviderTag) -> SyncProviderTag {
        let settled = settledSyncProvider(
            policy: coreArgument,
            offered: Self.offeredProviders,
            current: chosen,
            tableproSyncAvailable: true
        )
        switch (chosen, settled) {
        case (.tableproSync, .icloud):
            return .tableproSync
        case (.off, .tableproSync), (.icloud, .tableproSync):
            return .off
        default:
            return settled
        }
    }

    func settledICloudSync(_ chosen: Bool) -> Bool {
        settledProvider(chosen ? .icloud : .off) == .icloud
    }

    private static func string(_ values: [String: Any], _ key: String) -> String? {
        guard let value = values[key] else { return nil }
        guard let string = value as? String else {
            refused(key, expected: "string")
            return nil
        }
        return string
    }

    // A number is not a boolean, though NSNumber bridges both.
    private static func bool(_ values: [String: Any], _ key: String) -> Bool? {
        guard let value = values[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            refused(key, expected: "boolean")
            return nil
        }
        return number.boolValue
    }

    // An entry that is not a string is left out; the core skips a name it does not know.
    private static func strings(_ values: [String: Any], _ key: String) -> [String]? {
        guard let value = values[key] else { return nil }
        guard let list = value as? [Any] else {
            refused(key, expected: "stringArray")
            return nil
        }
        let names = list.compactMap { $0 as? String }
        if names.count != list.count {
            logger.warning("Managed \(key, privacy: .public) holds entries that are not strings, which are left out")
        }
        return names
    }

    private static func refused(_ key: String, expected: String) {
        logger.warning("Managed \(key, privacy: .public) is not a \(expected, privacy: .public), so it counts as absent")
    }
}

import Foundation
import os
import TableProFFI

// The keys an MDM sets for this app as managed app configuration (core/docs/decisions/0055-managed-policies-for-the-sync-
// provider-and-tablepro-app-traffic.md). The raw values go to the core, which applies them by the rule every app shares.
// Absent, or of another type, a key leaves the person's own setting.
nonisolated struct ManagedAppConfiguration: Equatable, Sendable {
    static let defaultsKey = "com.apple.configuration.managed"
    // Until TablePro Sync ships here, iOS offers Off and iCloud, and the iCloud switch is its picker.
    static let offeredProviders: [SyncProviderTag] = [.off, .icloud]

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
    var allowsICloudSync: Bool {
        iCloudChoices.providers.contains(.icloud)
    }

    // One choice or none: the iCloud switch is the organization's.
    var locksICloudSync: Bool {
        iCloudChoices.locked
    }

    // A forced iCloud turns sync on as the person would, and iCloud taken away turns it off; with a choice left, the
    // person's own stands.
    func settledICloudSync(_ chosen: Bool) -> Bool {
        settledSyncProvider(
            policy: coreArgument,
            offered: Self.offeredProviders,
            current: chosen ? .icloud : .off,
            tableproSyncAvailable: false
        ) == .icloud
    }

    private var iCloudChoices: PersonalSyncChoices {
        personalSyncChoices(policy: coreArgument, offered: Self.offeredProviders)
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

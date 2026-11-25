import Foundation
import os

nonisolated enum PersonalSyncProvider: String, Sendable, CaseIterable {
    case off
    case iCloud = "icloud"
    case tableProSync = "tablepro-sync"
}

// The keys an MDM sets for this app as managed app configuration (core/docs/decisions/0055-managed-policies-for-the-sync-
// provider-and-tablepro-app-traffic.md). Absent, or of another type, a key leaves the person's own setting.
nonisolated struct ManagedAppConfiguration: Equatable, Sendable {
    static let defaultsKey = "com.apple.configuration.managed"

    private static let logger = Logger(subsystem: "com.TablePro", category: "ManagedAppConfiguration")

    var accountServerURL: String?
    var allowOtherAccountServers: Bool?
    // Applied by the sync engine, which works out the choices from the raw list (0055, PersonalSyncProvider).
    var personalSyncProviders: Set<PersonalSyncProvider>?
    var usageDataAllowed: Bool?
    var iCloudSyncAllowed: Bool?

    static let unmanaged = ManagedAppConfiguration()

    var allowsUsageData: Bool {
        usageDataAllowed != false
    }

    var allowsICloudSync: Bool {
        iCloudSyncAllowed != false
    }

    // Only an MDM writes this dictionary: the app has no code that sets it.
    static func current(defaults: UserDefaults = .standard) -> ManagedAppConfiguration {
        ManagedAppConfiguration(defaults.dictionary(forKey: defaultsKey))
    }

    init(
        accountServerURL: String? = nil,
        allowOtherAccountServers: Bool? = nil,
        personalSyncProviders: Set<PersonalSyncProvider>? = nil,
        usageDataAllowed: Bool? = nil,
        iCloudSyncAllowed: Bool? = nil
    ) {
        self.accountServerURL = accountServerURL
        self.allowOtherAccountServers = allowOtherAccountServers
        self.personalSyncProviders = personalSyncProviders
        self.usageDataAllowed = usageDataAllowed
        self.iCloudSyncAllowed = iCloudSyncAllowed
    }

    init(_ values: [String: Any]?) {
        let values = values ?? [:]
        self.init(
            accountServerURL: Self.string(values, "AccountServerURL"),
            allowOtherAccountServers: Self.bool(values, "AllowOtherAccountServers"),
            personalSyncProviders: Self.providers(values, "PersonalSyncProvider"),
            usageDataAllowed: Self.bool(values, "UsageDataAllowed"),
            iCloudSyncAllowed: Self.bool(values, "ICloudSyncAllowed")
        )
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

    private static func providers(_ values: [String: Any], _ key: String) -> Set<PersonalSyncProvider>? {
        guard let value = values[key] else { return nil }
        guard let names = value as? [String] else {
            refused(key, expected: "stringArray")
            return nil
        }
        return Set(names.compactMap { name in
            guard let provider = PersonalSyncProvider(rawValue: name) else {
                logger.warning("PersonalSyncProvider names an unknown provider, skipped: \(name, privacy: .public)")
                return nil
            }
            return provider
        })
    }

    private static func refused(_ key: String, expected: String) {
        logger.warning("Managed \(key, privacy: .public) is not a \(expected, privacy: .public), so it counts as absent")
    }
}

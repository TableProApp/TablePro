//
//  ManagedPolicy.swift
//  TablePro
//

import Foundation
import os

// One flat key per decision: forcing an encoded settings struct would make an administrator reproduce all of it, and
// break when a field is added. core ADR 0055 lists the keys; the Safe Mode floor keeps the spelling profiles carry.
internal enum ManagedPolicy: String, CaseIterable, Sendable {
    // A floor, never a ceiling: a stricter level a connection chose is kept.
    case minimumSafeModeLevel = "com.TablePro.policy.minimumSafeModeLevel"
    case accountServerURL = "com.TablePro.policy.AccountServerURL"
    case allowOtherAccountServers = "com.TablePro.policy.AllowOtherAccountServers"
    case personalSyncProvider = "com.TablePro.policy.PersonalSyncProvider"
    case usageDataAllowed = "com.TablePro.policy.UsageDataAllowed"
    case pluginCatalogAllowed = "com.TablePro.policy.PluginCatalogAllowed"
    case iCloudSyncAllowed = "com.TablePro.policy.ICloudSyncAllowed"

    internal var key: String { rawValue }
}

internal protocol ManagedPolicyReading: Sendable {
    func string(_ policy: ManagedPolicy) -> String?
    func bool(_ policy: ManagedPolicy) -> Bool?
    func strings(_ policy: ManagedPolicy) -> [String]?
}

extension ManagedPolicyReading {
    func bool(_ policy: ManagedPolicy) -> Bool? { nil }
    func strings(_ policy: ManagedPolicy) -> [String]? { nil }
}

internal protocol ManagedPreferences {
    func object(forKey defaultName: String) -> Any?
    func objectIsForced(forKey key: String) -> Bool
}

extension UserDefaults: ManagedPreferences {}

// A value counts only when a configuration profile forces it (core ADR 0044, App configuration). The same key written
// with `defaults write` sits in the same search list and is not policy. A forced value of another type counts as
// absent (core ADR 0055, Keys).
internal struct ManagedPolicyReader: ManagedPolicyReading, @unchecked Sendable {
    internal static let shared = ManagedPolicyReader()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ManagedPolicy")
    // The Safe Mode floor is read before every query, so a wrong value is reported once a run.
    private static let reported = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    private let preferences: any ManagedPreferences

    // A configuration profile for com.TablePro lands in the standard domain, whatever sandbox a run uses.
    internal init(defaults: UserDefaults = .standard) {
        self.preferences = defaults
    }

    internal init(preferences: any ManagedPreferences) {
        self.preferences = preferences
    }

    internal func string(_ policy: ManagedPolicy) -> String? {
        guard let value = forcedValue(policy) else { return nil }
        guard let text = value as? String else {
            Self.report(policy, "is not a string, so it is ignored")
            return nil
        }
        return text
    }

    internal func bool(_ policy: ManagedPolicy) -> Bool? {
        guard let value = forcedValue(policy) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            Self.report(policy, "is not a boolean, so it is ignored")
            return nil
        }
        return number.boolValue
    }

    internal func strings(_ policy: ManagedPolicy) -> [String]? {
        guard let value = forcedValue(policy) else { return nil }
        guard let entries = value as? [Any] else {
            Self.report(policy, "is not an array, so it is ignored")
            return nil
        }
        let texts = entries.compactMap { $0 as? String }
        if texts.count != entries.count {
            Self.report(policy, "holds an entry that is not a string, so that entry is skipped")
        }
        return texts
    }

    private func forcedValue(_ policy: ManagedPolicy) -> Any? {
        guard preferences.objectIsForced(forKey: policy.key) else { return nil }
        return preferences.object(forKey: policy.key)
    }

    private static func report(_ policy: ManagedPolicy, _ problem: String) {
        let first = reported.withLock { $0.insert("\(policy.key) \(problem)").inserted }
        guard first else { return }
        logger.error("The managed value \(policy.key, privacy: .public) \(problem, privacy: .public)")
    }
}

// Every key a configuration profile forces, read together so each consumer sees one set of values.
internal struct ManagedPolicySnapshot: Equatable, Sendable {
    var accountServerURL: String?
    var allowOtherAccountServers: Bool?
    var personalSyncProvider: [String]?
    var usageDataAllowed: Bool?
    var pluginCatalogAllowed: Bool?
    var iCloudSyncAllowed: Bool?

    init(
        accountServerURL: String? = nil,
        allowOtherAccountServers: Bool? = nil,
        personalSyncProvider: [String]? = nil,
        usageDataAllowed: Bool? = nil,
        pluginCatalogAllowed: Bool? = nil,
        iCloudSyncAllowed: Bool? = nil
    ) {
        self.accountServerURL = accountServerURL
        self.allowOtherAccountServers = allowOtherAccountServers
        self.personalSyncProvider = personalSyncProvider
        self.usageDataAllowed = usageDataAllowed
        self.pluginCatalogAllowed = pluginCatalogAllowed
        self.iCloudSyncAllowed = iCloudSyncAllowed
    }

    init(reading policy: any ManagedPolicyReading) {
        self.init(
            accountServerURL: policy.string(.accountServerURL),
            allowOtherAccountServers: policy.bool(.allowOtherAccountServers),
            personalSyncProvider: policy.strings(.personalSyncProvider),
            usageDataAllowed: policy.bool(.usageDataAllowed),
            pluginCatalogAllowed: policy.bool(.pluginCatalogAllowed),
            iCloudSyncAllowed: policy.bool(.iCloudSyncAllowed)
        )
    }

    // A boolean that is true or absent leaves the person's own setting.
    var allowsUsageData: Bool { usageDataAllowed != false }
    var allowsPluginCatalog: Bool { pluginCatalogAllowed != false }
    var allowsICloudSync: Bool { iCloudSyncAllowed != false }
}

internal enum ManagedPolicyResolver {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ManagedPolicy")

    // An unknown level is no floor: a profile naming a level this build lacks must become neither Read-Only nor Silent.
    internal static func effectiveSafeModeLevel(
        connectionLevel: SafeModeLevel,
        policy: any ManagedPolicyReading
    ) -> SafeModeLevel {
        guard let floor = minimumSafeModeLevel(policy: policy) else { return connectionLevel }
        return floor.strictness > connectionLevel.strictness ? floor : connectionLevel
    }

    internal static func minimumSafeModeLevel(policy: any ManagedPolicyReading) -> SafeModeLevel? {
        guard let value = policy.string(.minimumSafeModeLevel) else { return nil }
        guard let level = SafeModeLevel(rawValue: value) else {
            logger.error("minimumSafeModeLevel names no Safe Mode level this build has, so it sets no floor")
            return nil
        }
        return level
    }
}

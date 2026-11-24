//
//  ManagedPolicy.swift
//  TablePro
//

import Foundation

// One flat key per decision: forcing an encoded settings struct would make an administrator reproduce all of it, and
// break when a field is added. Keys added from core ADR 0044 on follow its spelling.
internal enum ManagedPolicy: String, CaseIterable, Sendable {
    // A floor, never a ceiling: a stricter level a connection chose is kept.
    case minimumSafeModeLevel = "com.TablePro.policy.minimumSafeModeLevel"
    case accountServerURL = "com.TablePro.policy.AccountServerURL"
    case allowOtherAccountServers = "com.TablePro.policy.AllowOtherAccountServers"

    internal var key: String { rawValue }
}

internal protocol ManagedPolicyReading: Sendable {
    func string(_ policy: ManagedPolicy) -> String?
    func bool(_ policy: ManagedPolicy) -> Bool?
}

extension ManagedPolicyReading {
    func bool(_ policy: ManagedPolicy) -> Bool? { nil }
}

internal protocol ManagedPreferences {
    func object(forKey defaultName: String) -> Any?
    func objectIsForced(forKey key: String) -> Bool
}

extension UserDefaults: ManagedPreferences {}

// A value counts only when a configuration profile forces it (core ADR 0044, App configuration). The same key written
// with `defaults write` sits in the same search list and is not policy.
internal struct ManagedPolicyReader: ManagedPolicyReading, @unchecked Sendable {
    internal static let shared = ManagedPolicyReader()

    private let preferences: any ManagedPreferences

    // A configuration profile for com.TablePro lands in the standard domain, whatever sandbox a run uses.
    internal init(defaults: UserDefaults = .standard) {
        self.preferences = defaults
    }

    internal init(preferences: any ManagedPreferences) {
        self.preferences = preferences
    }

    internal func string(_ policy: ManagedPolicy) -> String? {
        forcedValue(policy) as? String
    }

    internal func bool(_ policy: ManagedPolicy) -> Bool? {
        guard let number = forcedValue(policy) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private func forcedValue(_ policy: ManagedPolicy) -> Any? {
        guard preferences.objectIsForced(forKey: policy.key) else { return nil }
        return preferences.object(forKey: policy.key)
    }
}

internal enum ManagedPolicyResolver {
    // An unknown level is no floor: a profile naming a level this build lacks must become neither Read-Only nor Silent.
    internal static func effectiveSafeModeLevel(
        connectionLevel: SafeModeLevel,
        policy: any ManagedPolicyReading
    ) -> SafeModeLevel {
        guard let floor = minimumSafeModeLevel(policy: policy) else { return connectionLevel }
        return floor.strictness > connectionLevel.strictness ? floor : connectionLevel
    }

    internal static func minimumSafeModeLevel(policy: any ManagedPolicyReading) -> SafeModeLevel? {
        policy.string(.minimumSafeModeLevel).flatMap(SafeModeLevel.init(rawValue:))
    }
}

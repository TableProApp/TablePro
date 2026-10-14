//
//  ManagedPolicy.swift
//  TablePro
//

import Foundation

/// Settings an administrator can impose through a configuration profile, and that the user cannot
/// then turn off.
///
/// Each policy is one flat, primitive key. The app's own settings are stored as encoded structs
/// under keys like `com.TablePro.settings.mcp`, which cannot serve as policy: forcing one would mean
/// an administrator had to reproduce the whole struct, and it would break the moment a field was
/// added. A profile delivers one key per decision instead.
internal enum ManagedPolicy: String, CaseIterable, Sendable {
    /// The weakest Safe Mode level a connection may run at. A connection set to something weaker is
    /// raised to this; a stronger choice is left alone, so the policy is a floor and never a ceiling.
    case minimumSafeModeLevel = "com.TablePro.policy.minimumSafeModeLevel"

    internal var key: String { rawValue }
}

internal protocol ManagedPolicyReading: Sendable {
    func string(_ policy: ManagedPolicy) -> String?
}

/// Reads policy out of the standard preferences chain. macOS merges a configuration profile's
/// values into `UserDefaults` at the highest priority, so the forced value simply wins.
internal struct ManagedPolicyReader: ManagedPolicyReading, @unchecked Sendable {
    internal static let shared = ManagedPolicyReader()

    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    internal func string(_ policy: ManagedPolicy) -> String? {
        defaults.string(forKey: policy.key)
    }
}

internal enum ManagedPolicyResolver {
    /// Raises a connection's Safe Mode level to the managed floor, leaving a stricter choice alone.
    ///
    /// An unset or unrecognised policy value means no floor rather than a default one. A profile that
    /// names a level TablePro does not know must not silently become Read-Only, and must not silently
    /// become Silent either.
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

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

    /// Stops the MCP server from listening, so an AI client cannot reach the databases at all.
    case mcpServerDisabled = "com.TablePro.policy.mcpServerDisabled"

    /// Stops the in-app AI assistant, including inline suggestions.
    case aiAssistantDisabled = "com.TablePro.policy.aiAssistantDisabled"

    /// Stops plugins being installed, from the registry or from a file.
    case pluginInstallDisabled = "com.TablePro.policy.pluginInstallDisabled"

    internal var key: String { rawValue }
}

internal protocol ManagedPolicyReading: Sendable {
    /// True when a configuration profile supplies this key, so the UI for it must be disabled.
    func isManaged(_ policy: ManagedPolicy) -> Bool
    func bool(_ policy: ManagedPolicy) -> Bool
    func string(_ policy: ManagedPolicy) -> String?
}

/// Reads policy out of the standard preferences chain.
///
/// macOS already merges a configuration profile's values into `UserDefaults` at the highest
/// priority, so reading a managed key needs no special path: the forced value simply wins. The one
/// thing the normal API cannot tell you is *whether* a key was forced, which is what
/// `CFPreferencesAppValueIsForced` is for. Its own header says callers "should use this function to
/// determine whether or not to disable UI elements corresponding to those preference keys".
internal struct ManagedPolicyReader: ManagedPolicyReading, @unchecked Sendable {
    internal static let shared = ManagedPolicyReader()

    private let defaults: UserDefaults
    private let applicationID: String

    internal init(defaults: UserDefaults = .standard, applicationID: String = Bundle.main.bundleIdentifier ?? "") {
        self.defaults = defaults
        self.applicationID = applicationID
    }

    internal func isManaged(_ policy: ManagedPolicy) -> Bool {
        guard !applicationID.isEmpty else { return false }
        return CFPreferencesAppValueIsForced(policy.key as CFString, applicationID as CFString)
    }

    internal func bool(_ policy: ManagedPolicy) -> Bool {
        defaults.bool(forKey: policy.key)
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
        guard let raw = policy.string(.minimumSafeModeLevel),
              let floor = SafeModeLevel(rawValue: raw)
        else { return connectionLevel }
        return strictness(floor) > strictness(connectionLevel) ? floor : connectionLevel
    }

    /// Ordered weakest to strongest by what each level actually prevents, not by declaration order.
    private static func strictness(_ level: SafeModeLevel) -> Int {
        switch level {
        case .silent: 0
        case .alert: 1
        case .alertFull: 2
        case .safeMode: 3
        case .safeModeFull: 4
        case .readOnly: 5
        }
    }
}

//
//  PluginDeveloperTrustStore.swift
//  TablePro
//

import Foundation
import os

internal struct TrustedPluginDeveloper: Codable, Hashable, Identifiable, Sendable {
    internal let identity: PluginDeveloperIdentity
    internal let trustedAt: Date

    internal var id: String { identity.teamID }
}

internal protocol PluginDeveloperTrustChecking: Sendable {
    func isTrusted(_ identity: PluginDeveloperIdentity) -> Bool
    func trust(_ identity: PluginDeveloperIdentity)
    func revoke(teamID: String)
    func trustedDevelopers() -> [TrustedPluginDeveloper]
}

/// Consent is recorded per Apple Team ID, not per plugin, so a developer the user already trusts can
/// ship an update without asking again, and revoking one developer revokes every plugin they signed.
///
/// Not main-actor bound: the plugin load path runs off the main actor and has to read trust before
/// it loads a bundle. `UserDefaults` is thread safe, and this type holds no other state.
internal final class PluginDeveloperTrustStore: PluginDeveloperTrustChecking, @unchecked Sendable {
    internal static let shared = PluginDeveloperTrustStore()

    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginDeveloperTrust")
    private static let storageKey = "com.TablePro.pluginDeveloperTrust.entries"

    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    internal func isTrusted(_ identity: PluginDeveloperIdentity) -> Bool {
        guard !identity.teamID.isEmpty else { return false }
        return entries().contains { $0.identity.teamID == identity.teamID }
    }

    internal func trust(_ identity: PluginDeveloperIdentity) {
        guard !identity.teamID.isEmpty else {
            Self.logger.error("Refused to trust a plugin developer with no team identifier")
            return
        }
        var updated = entries().filter { $0.identity.teamID != identity.teamID }
        updated.append(TrustedPluginDeveloper(identity: identity, trustedAt: Date()))
        persist(updated)
        Self.logger.info("Trusted plugin developer \(identity.teamID, privacy: .public)")
    }

    internal func revoke(teamID: String) {
        persist(entries().filter { $0.identity.teamID != teamID })
        Self.logger.info("Revoked plugin developer \(teamID, privacy: .public)")
    }

    internal func trustedDevelopers() -> [TrustedPluginDeveloper] {
        entries().sorted { $0.trustedAt > $1.trustedAt }
    }

    private func entries() -> [TrustedPluginDeveloper] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([TrustedPluginDeveloper].self, from: data)
        } catch {
            Self.logger.error("Could not decode trusted plugin developers: \(error.localizedDescription)")
            return []
        }
    }

    private func persist(_ entries: [TrustedPluginDeveloper]) {
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: Self.storageKey)
        } catch {
            Self.logger.error("Could not persist trusted plugin developers: \(error.localizedDescription)")
        }
    }
}

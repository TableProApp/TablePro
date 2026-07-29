//
//  ExternalConnectionTrustStore.swift
//  TablePro
//

import Foundation
import os

internal struct TrustedExternalConnection: Codable, Hashable, Identifiable, Sendable {
    internal let key: ExternalConnectionTrustKey
    internal let trustedAt: Date

    internal var id: ExternalConnectionTrustKey { key }
}

@MainActor
internal protocol ExternalConnectionTrustChecking {
    func isTrusted(_ key: ExternalConnectionTrustKey) -> Bool
    func trust(_ key: ExternalConnectionTrustKey)
}

@MainActor
internal final class ExternalConnectionTrustStore: ExternalConnectionTrustChecking {
    internal static let shared = ExternalConnectionTrustStore()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ExternalConnectionTrustStore")
    private static let storageKey = "com.TablePro.externalConnectionTrust.entries"

    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    internal func isTrusted(_ key: ExternalConnectionTrustKey) -> Bool {
        guard key.isLoopbackHost else { return false }
        return entries().contains { $0.key == key }
    }

    internal func trust(_ key: ExternalConnectionTrustKey) {
        guard key.isLoopbackHost else {
            Self.logger.error("Refused to trust non-loopback external connection")
            return
        }
        var updated = entries().filter { $0.key != key }
        updated.append(TrustedExternalConnection(key: key, trustedAt: Date()))
        save(updated)
        Self.logger.info("Trusted external connection \(key.displayDescription, privacy: .public)")
    }

    internal func revoke(_ key: ExternalConnectionTrustKey) {
        save(entries().filter { $0.key != key })
    }

    internal func revokeAll() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    internal func entries() -> [TrustedExternalConnection] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([TrustedExternalConnection].self, from: data)
        else { return [] }
        return decoded.filter { $0.key.isLoopbackHost }
    }

    private func save(_ entries: [TrustedExternalConnection]) {
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

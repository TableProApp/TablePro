import Combine
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

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ExternalConnectionTrustStore")
    private static let storageKey = JSONDefaultsKey<[TrustedExternalConnection]>(
        "com.TablePro.externalConnectionTrust.entries"
    )

    private let defaults: UserDefaults
    private let changeSubject = PassthroughSubject<Void, Never>()

    internal init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
    }

    // Sent after the write, so a subscriber that reads entries() sees the change.
    internal var changes: AnyPublisher<Void, Never> {
        changeSubject.eraseToAnyPublisher()
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
        Self.logger.info("Trusted external connection \(key.displayDescription, privacy: .private(mask: .hash))")
        changeSubject.send(())
    }

    internal func revoke(_ key: ExternalConnectionTrustKey) {
        save(entries().filter { $0.key != key })
        changeSubject.send(())
    }

    internal func revokeAll() {
        defaults.removeValue(for: Self.storageKey)
        changeSubject.send(())
    }

    internal func entries() -> [TrustedExternalConnection] {
        (defaults.read(Self.storageKey).value ?? []).filter { $0.key.isLoopbackHost }
    }

    private func save(_ entries: [TrustedExternalConnection]) {
        guard !entries.isEmpty else {
            defaults.removeValue(for: Self.storageKey)
            return
        }
        try? defaults.write(entries, to: Self.storageKey)
    }
}

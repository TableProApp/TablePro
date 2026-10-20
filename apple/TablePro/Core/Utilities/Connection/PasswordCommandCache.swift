//
//  PasswordCommandCache.swift
//  TablePro
//

import Foundation

// In memory only: a password command's output is a secret and never reaches disk.
final class PasswordCommandCache: @unchecked Sendable {
    static let shared = PasswordCommandCache()

    private struct Key: Hashable {
        let connectionId: UUID
        let command: String
        let environment: [String: String]
        let lifetime: Duration
    }

    private struct Entry {
        let password: String
        let expiresAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private var entries: [Key: Entry] = [:]

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    func password(
        connectionId: UUID,
        command: String,
        environment: [String: String],
        lifetime: Duration,
        resolve: () async throws -> String
    ) async throws -> String {
        let key = Key(connectionId: connectionId, command: command, environment: environment, lifetime: lifetime)
        if let cached = lock.withLock({ entries[key] }), cached.expiresAt > now() {
            return cached.password
        }
        let password = try await resolve()
        lock.withLock {
            let current = now()
            entries = entries.filter { $0.value.expiresAt > current }
            entries[key] = Entry(password: password, expiresAt: current + lifetime)
        }
        return password
    }

    func forget(connectionId: UUID) {
        lock.withLock {
            entries = entries.filter { $0.key.connectionId != connectionId }
        }
    }
}

//
//  ResolvedPasswordCache.swift
//  TablePro
//

import Foundation
import os

/// Passwords a secret manager has already handed over, held in memory for as long as the user's
/// cache lifetime allows.
///
/// In memory and nowhere else. Writing a fetched secret to the Keychain would make TablePro a
/// second copy of the vault the user deliberately keeps their passwords in, and it would outlive
/// the revocation that vault exists to make possible.
///
/// The fingerprint is the exact command that produced the entry, so editing a connection's command
/// or the shared template drops the entry without anything having to remember to invalidate it.
actor ResolvedPasswordCache {
    static let shared = ResolvedPasswordCache()

    private struct Entry {
        let password: String
        let fingerprint: String
        let expiresAt: Date
    }

    private var entries: [UUID: Entry] = [:]

    func value(for connectionId: UUID, fingerprint: String, now: Date = Date()) -> String? {
        guard let entry = entries[connectionId] else { return nil }
        guard entry.fingerprint == fingerprint, entry.expiresAt > now else {
            entries[connectionId] = nil
            return nil
        }
        return entry.password
    }

    func store(
        _ password: String,
        for connectionId: UUID,
        fingerprint: String,
        lifetime: TimeInterval,
        now: Date = Date()
    ) {
        guard lifetime > 0 else {
            entries[connectionId] = nil
            return
        }
        purgeExpired(now: now)
        entries[connectionId] = Entry(
            password: password,
            fingerprint: fingerprint,
            expiresAt: now.addingTimeInterval(lifetime)
        )
    }

    func invalidate(_ connectionId: UUID) {
        entries[connectionId] = nil
    }

    func invalidateAll() {
        entries.removeAll()
    }

    var count: Int {
        entries.count
    }

    private func purgeExpired(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }
}

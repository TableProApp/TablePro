//
//  EnvVarReferenceApprovalStore.swift
//  TablePro
//

import Foundation
import os
import TableProConnectionLibrary

// Device-local, so a definition that arrives with another destination or another name asks again.
@MainActor
internal final class EnvVarReferenceApprovalStore {
    internal static let shared = EnvVarReferenceApprovalStore()

    // Connection id, then destination digest, then the sorted names approved for it.
    private typealias Approvals = [String: [String: [String]]]

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "EnvVarReferenceApprovalStore")
    private static let storageKey = "com.TablePro.envVarReferenceApprovals"
    private static let migratedKey = "com.TablePro.envVarApprovalsMigrated"

    private let defaults: UserDefaults
    private let savedConnections: @MainActor () -> [DatabaseConnection]?

    internal init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        savedConnections: @escaping @MainActor () -> [DatabaseConnection]? = EnvVarReferenceApprovalStore
            .trustedSavedConnections
    ) {
        self.defaults = defaults
        self.savedConnections = savedConnections
    }

    internal func isApproved(_ connection: DatabaseConnection) -> Bool {
        let names = EnvVarResolver.referencedNames(in: connection)
        guard !names.isEmpty else { return true }
        migrateIfNeeded()
        let approved = approvals()[connection.id.uuidString]?[connection.destination.digest] ?? []
        return names.isSubset(of: approved)
    }

    internal func approveReferences(of connection: DatabaseConnection) {
        migrateIfNeeded()
        var all = approvals()
        guard record(connection, in: &all) else { return }
        save(all)
        Self.logger.info("Approved environment variable references for a connection")
    }

    internal func revoke(for connectionId: UUID) {
        var all = approvals()
        guard all.removeValue(forKey: connectionId.uuidString) != nil else { return }
        save(all)
    }

    internal func copyApprovals(from source: UUID, to destination: UUID) {
        migrateIfNeeded()
        var all = approvals()
        guard let copied = all[source.uuidString], !copied.isEmpty else { return }
        all[destination.uuidString, default: [:]].merge(copied) { kept, added in
            Set(kept).union(added).sorted()
        }
        save(all)
    }

    // Trust on first use for rows this Mac made; an import or sync insert before the first use still asks.
    internal func migrateIfNeeded() {
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        guard let connections = savedConnections() else { return }
        var all = approvals()
        var changed = false
        for connection in connections where connection.origin == .thisMac {
            changed = record(connection, in: &all) || changed
        }
        if changed {
            save(all)
        }
        defaults.set(true, forKey: Self.migratedKey)
    }

    // Nil waits for a readable library; a file changed outside TablePro approves nothing.
    internal static func trustedSavedConnections() -> [DatabaseConnection]? {
        let storage = ConnectionStorage.shared
        let connections = storage.loadConnections()
        guard !storage.lastLoadFailed else { return nil }
        return storage.storeIsTrusted ? connections : []
    }

    private func record(_ connection: DatabaseConnection, in all: inout Approvals) -> Bool {
        let names = EnvVarResolver.referencedNames(in: connection)
        guard !names.isEmpty else { return false }
        let digest = connection.destination.digest
        let approved = Set(all[connection.id.uuidString]?[digest] ?? []).union(names)
        all[connection.id.uuidString, default: [:]][digest] = approved.sorted()
        return true
    }

    private func approvals() -> Approvals {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(Approvals.self, from: data)
        else { return [:] }
        return decoded
    }

    private func save(_ approvals: Approvals) {
        let kept = approvals.filter { !$0.value.isEmpty }
        guard !kept.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(kept) else {
            Self.logger.error("Could not encode environment variable approvals")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}

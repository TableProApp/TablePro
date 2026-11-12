//
//  ConnectionApprovalStore.swift
//  TablePro
//

import Foundation
import os
import TableProConnectionLibrary

// Device-local, so a definition that arrives with another destination or asks for more asks again.
@MainActor
internal final class ConnectionApprovalStore {
    internal enum Kind: Sendable {
        case envVarReferences
        case localCredentials
    }

    internal static let envVarReferences = ConnectionApprovalStore(kind: .envVarReferences)
    internal static let localCredentials = ConnectionApprovalStore(kind: .localCredentials)

    internal static var all: [ConnectionApprovalStore] {
        [envVarReferences, localCredentials]
    }

    // Connection id, then destination digest, then the sorted items approved for it.
    private typealias Approvals = [String: [String: [String]]]

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionApprovalStore")

    private let kind: Kind
    private let defaults: UserDefaults
    private let savedConnections: @MainActor () -> [DatabaseConnection]?
    private let dialedDestination: @MainActor (DatabaseConnection) -> ConnectionDestination

    internal init(
        kind: Kind,
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        savedConnections: @escaping @MainActor () -> [DatabaseConnection]? = ConnectionApprovalStore
            .trustedSavedConnections,
        dialedDestination: @escaping @MainActor (DatabaseConnection) -> ConnectionDestination = { $0.dialedDestination }
    ) {
        self.kind = kind
        self.defaults = defaults
        self.savedConnections = savedConnections
        self.dialedDestination = dialedDestination
    }

    internal func isApproved(_ connection: DatabaseConnection) -> Bool {
        let items = kind.items(in: connection)
        guard !items.isEmpty else { return true }
        migrateIfNeeded()
        let approved = approvals()[connection.id.uuidString]?[dialedDestination(connection).digest] ?? []
        return items.isSubset(of: approved)
    }

    internal func approve(_ connection: DatabaseConnection) {
        migrateIfNeeded()
        var all = approvals()
        guard record(connection, in: &all) else { return }
        save(all)
        Self.logger.info("Approved \(self.kind.logName, privacy: .public) for a connection")
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
        guard !defaults.bool(forKey: kind.migratedKey) else { return }
        guard let connections = savedConnections() else { return }
        var all = approvals()
        var changed = false
        for connection in connections where connection.origin == .thisMac {
            changed = record(connection, in: &all) || changed
        }
        if changed {
            save(all)
        }
        defaults.set(true, forKey: kind.migratedKey)
    }

    // Nil waits for a readable library; a file changed outside TablePro approves nothing.
    internal static func trustedSavedConnections() -> [DatabaseConnection]? {
        let storage = ConnectionStorage.shared
        let connections = storage.loadConnections()
        guard !storage.lastLoadFailed else { return nil }
        return storage.storeIsTrusted ? connections : []
    }

    private func record(_ connection: DatabaseConnection, in all: inout Approvals) -> Bool {
        let items = kind.items(in: connection)
        guard !items.isEmpty else { return false }
        let digest = dialedDestination(connection).digest
        let approved = Set(all[connection.id.uuidString]?[digest] ?? []).union(items)
        all[connection.id.uuidString, default: [:]][digest] = approved.sorted()
        return true
    }

    private func approvals() -> Approvals {
        guard let data = defaults.data(forKey: kind.storageKey),
              let decoded = try? JSONDecoder().decode(Approvals.self, from: data)
        else { return [:] }
        return decoded
    }

    private func save(_ approvals: Approvals) {
        let kept = approvals.filter { !$0.value.isEmpty }
        guard !kept.isEmpty else {
            defaults.removeObject(forKey: kind.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(kept) else {
            Self.logger.error("Could not encode \(self.kind.logName, privacy: .public)")
            return
        }
        defaults.set(data, forKey: kind.storageKey)
    }
}

extension ConnectionApprovalStore.Kind {
    // Variable names, or each field that signs in with something this Mac holds, with its value.
    internal func items(in connection: DatabaseConnection) -> Set<String> {
        switch self {
        case .envVarReferences:
            EnvVarResolver.referencedNames(in: connection)
        case .localCredentials:
            Set(ConnectionFieldCatalog.localCredentialUses(in: connection.additionalFields).map { use in
                use.fieldId + "=" + use.value
            })
        }
    }

    fileprivate var storageKey: String {
        switch self {
        case .envVarReferences: "com.TablePro.envVarReferenceApprovals"
        case .localCredentials: "com.TablePro.localCredentialApprovals"
        }
    }

    fileprivate var migratedKey: String {
        switch self {
        case .envVarReferences: "com.TablePro.envVarApprovalsMigrated"
        case .localCredentials: "com.TablePro.localCredentialApprovalsMigrated"
        }
    }

    fileprivate var logName: String {
        switch self {
        case .envVarReferences: "environment variable references"
        case .localCredentials: "local credential use"
        }
    }
}

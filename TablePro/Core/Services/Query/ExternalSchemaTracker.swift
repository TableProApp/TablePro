//
//  ExternalSchemaTracker.swift
//  TablePro
//

import Foundation
import os

@MainActor
@Observable
final class ExternalSchemaTracker {
    static let shared = ExternalSchemaTracker()

    struct Key: Hashable, Sendable {
        let connectionId: UUID
        let database: String
    }

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ExternalSchemaTracker")

    private var namesByDatabase: [Key: Set<String>] = [:]

    @ObservationIgnored private let dedup = OnceTask<Key, Set<String>>()

    private init() {}

    func isExternal(connectionId: UUID, database: String, schema: String) -> Bool {
        namesByDatabase[Key(connectionId: connectionId, database: database)]?.contains(schema) ?? false
    }

    func load(connectionId: UUID, database: String, driver: DatabaseDriver) async {
        let key = Key(connectionId: connectionId, database: database)
        guard namesByDatabase[key] == nil else { return }
        do {
            let names = try await dedup.execute(key: key) {
                try await driver.fetchExternalSchemaNames()
            }
            namesByDatabase[key] = names
        } catch {
            Self.logger.warning(
                "Could not load external schema names for \(database, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            namesByDatabase[key] = []
        }
    }

    func reset(connectionId: UUID) {
        namesByDatabase = namesByDatabase.filter { $0.key.connectionId != connectionId }
    }
}

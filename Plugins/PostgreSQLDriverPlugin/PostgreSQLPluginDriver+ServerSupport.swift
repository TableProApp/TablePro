//
//  PostgreSQLPluginDriver+ServerSupport.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os
import TableProPluginKit

internal extension PostgreSQLPluginDriver {
    private static let sessionLogger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "PostgreSQLSession")

    var connectedDatabase: String? {
        sessionFacts.withLock { $0.database }
    }

    var unsupportedStructureColumnFields: Set<StructureColumnField> {
        PostgreSQLVersionedStatements.unsupportedStructureColumnFields(capabilities: versionedCapabilities)
    }

    var unsupportedIndexTypes: Set<String> {
        PostgreSQLVersionedStatements.unsupportedIndexTypes(capabilities: versionedCapabilities)
    }

    func schemaOperationRefusal(_ operation: PluginSchemaOperation) -> String? {
        PostgreSQLVersionedStatements.refusal(for: operation, capabilities: versionedCapabilities)
    }

    func probeSessionFacts() async {
        do {
            let result = try await core.execute(query: PostgreSQLSessionFacts.probeQuery)
            let row = result.rows.first?.map(\.asText) ?? []
            let facts = PostgreSQLSessionFacts(probeRow: row)
            sessionFacts.withLock { $0 = facts }
        } catch {
            sessionFacts.withLock { $0 = .unknown }
            Self.sessionLogger.error(
                "Session probe failed; DDL falls back to forms every server accepts: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

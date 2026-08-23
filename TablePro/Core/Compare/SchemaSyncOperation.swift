//
//  SchemaSyncOperation.swift
//  TablePro
//
//  Table-level sync operations. SchemaChange covers everything inside one
//  table; this covers the table's own lifecycle, which SchemaStatementGenerator
//  deliberately does not model because it is scoped to a single fixed table.
//

import Foundation
import TableProPluginKit

internal enum SchemaSyncOperation: Identifiable {
    case createTable(TableStructureSnapshot)
    case dropTable(name: String, schema: String?)
    case alterTable(name: String, schema: String?, changes: [SchemaChange])

    internal var id: String {
        switch self {
        case .createTable(let snapshot): return "create-\(snapshot.qualifiedName)"
        case .dropTable(let name, let schema): return "drop-\(Self.qualify(name, schema))"
        case .alterTable(let name, let schema, _): return "alter-\(Self.qualify(name, schema))"
        }
    }

    internal var tableName: String {
        switch self {
        case .createTable(let snapshot): return snapshot.name
        case .dropTable(let name, _): return name
        case .alterTable(let name, _, _): return name
        }
    }

    internal var schema: String? {
        switch self {
        case .createTable(let snapshot): return snapshot.schema
        case .dropTable(_, let schema): return schema
        case .alterTable(_, let schema, _): return schema
        }
    }

    internal var tableIdentifier: String {
        Self.qualify(tableName, schema)
    }

    internal static func qualify(_ name: String, _ schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }
}

internal struct SyncStatement: Identifiable, Hashable, Sendable {
    internal let id: UUID
    internal let sql: String
    internal let objectName: String
    internal let summary: String
    internal let hazards: [SyncHazard]

    internal init(
        id: UUID = UUID(),
        sql: String,
        objectName: String,
        summary: String,
        hazards: [SyncHazard] = []
    ) {
        self.id = id
        self.sql = sql
        self.objectName = objectName
        self.summary = summary
        self.hazards = hazards
    }

    internal var isRefusedByDefault: Bool {
        hazards.contains { $0.severity == .refusedByDefault }
    }

    internal var highestSeverity: SyncHazardSeverity? {
        hazards.map { $0.severity }.max()
    }
}

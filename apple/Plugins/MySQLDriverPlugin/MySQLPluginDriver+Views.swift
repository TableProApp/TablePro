//
//  MySQLPluginDriver+Views.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MySQLPluginDriver {
    /// MySQL and MariaDB only: TiDB, OceanBase and Databend store view definitions in other forms.
    func fetchViewRowEditing(view: String, schema: String?) async throws -> PluginViewRowEditing? {
        switch flavor {
        case .mysql, .mariadb: break
        default: return nil
        }
        let escape = escapeStringLiteral
        let viewResult = try await execute(
            ownStatement: MySQLViewRowEditing.viewQuery(name: view, database: schema, escape: escape)
        )
        guard let row = viewResult.rows.first else { return nil }
        let isUpdatable = row[safe: 0]?.asText?.uppercased() == "YES"
        let definition = (row[safe: 1]?.asText).flatMap(MySQLViewRowEditing.parse(definition:))
        guard isUpdatable, let baseTable = definition?.baseTable else {
            return MySQLViewRowEditing.resolve(isUpdatable: isUpdatable, definition: definition, baseKeyColumns: [])
        }
        let keyResult = try await execute(
            ownStatement: MySQLViewRowEditing.primaryKeyQuery(table: baseTable, viewDatabase: schema, escape: escape)
        )
        return MySQLViewRowEditing.resolve(
            isUpdatable: isUpdatable,
            definition: definition,
            baseKeyColumns: keyResult.rows.compactMap { $0[safe: 0]?.asText }
        )
    }
}

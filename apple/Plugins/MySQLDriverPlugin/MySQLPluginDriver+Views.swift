//
//  MySQLPluginDriver+Views.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MySQLPluginDriver {
    // TiDB, OceanBase and Databend store view definitions in other forms.
    func fetchViewRowEditing(view: String, schema: String?) async throws -> PluginViewRowEditing? {
        switch flavor {
        case .mysql, .mariadb: break
        default: return nil
        }
        let escape = escapeStringLiteral
        let topRows = try await catalogRows(MySQLViewRowEditing.viewQuery(database: schema, name: view, escape: escape))
        guard let top = MySQLViewRowEditing.view(rows: topRows) else { return nil }
        // Once the relation proved to be a view, a failed read must not let it pass for a table.
        do {
            return try await rowEditing(through: top, escape: escape)
        } catch {
            return .readOnly(.couldNotCheck)
        }
    }

    private func rowEditing(
        through top: MySQLViewRowEditing.View,
        escape: (String) -> String
    ) async throws -> PluginViewRowEditing {
        var levels: [MySQLViewRowEditing.Level] = []
        var next: MySQLViewRowEditing.View? = top
        while let current = next {
            guard levels.count < MySQLViewRowEditing.maximumDepth else { return .readOnly(.notUpdatable) }
            let columnRows = try await catalogRows(MySQLViewRowEditing.columnsQuery(current.relation, escape: escape))
            switch try MySQLViewRowEditing.step(view: current, columnRows: columnRows) {
            case .readOnly(let reason):
                return .readOnly(reason)
            case .reads(let level):
                levels.append(level)
                let innerRows = try await catalogRows(
                    MySQLViewRowEditing.viewQuery(database: level.base.database, name: level.base.name, escape: escape)
                )
                next = MySQLViewRowEditing.view(rows: innerRows)
            }
        }

        guard let base = levels.last?.base else { return .readOnly(.notUpdatable) }
        let keyRows = try await catalogRows(MySQLViewRowEditing.primaryKeyQuery(base, escape: escape))
        let baseColumnRows = try await catalogRows(MySQLViewRowEditing.columnsQuery(base, escape: escape))
        return MySQLViewRowEditing.answer(
            levels: levels,
            keyRows: keyRows,
            columnRows: baseColumnRows,
            quotesDefaults: catalogQuotesDefaults,
            insertNeedsPlainColumns: flavor == .mysql
        )
    }

    private func catalogRows(_ statement: String) async throws -> [[String?]] {
        try await execute(ownStatement: statement).rows.map { $0.map(\.asText) }
    }
}

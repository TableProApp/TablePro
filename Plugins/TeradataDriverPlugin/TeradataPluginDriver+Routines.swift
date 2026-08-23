//
//  TeradataPluginDriver+Routines.swift
//  TeradataDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProTeradataCore

extension TeradataPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        guard let database = routineDatabase(schema) else { return [] }
        let result = try await execute(query: TeradataObjectQueries.routineList(database: database))
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = cellText(row, 0)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                return nil
            }
            let kind = cellText(row, 1)?.trimmingCharacters(in: .whitespaces)
            var attributes: [PluginObjectAttribute] = []
            if let kind, !kind.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Table Kind", value: kind))
            }
            if let creator = cellText(row, 4)?.trimmingCharacters(in: .whitespaces), !creator.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Creator", value: creator))
            }
            return PluginRoutineInfo(
                name: name,
                kind: TeradataObjectQueries.isProcedure(kind: kind) ? .procedure : .function,
                schema: cellText(row, 2)?.trimmingCharacters(in: .whitespaces) ?? database,
                returnType: nil,
                language: "SQL",
                argumentSignature: nil,
                identity: nil,
                definition: cellText(row, 3),
                attributes: attributes
            )
        }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        if let requestText = routine.definition?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestText.isEmpty {
            return requestText
        }
        guard let database = routineDatabase(routine.schema) else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        let query = TeradataObjectQueries.routineDefinition(
            kind: routine.kind == .procedure ? TeradataObjectQueries.TableKind.storedProcedure : "F",
            database: database,
            name: routine.name
        )
        let result = try await execute(query: query)
        let text = result.rows
            .compactMap { cellText($0, 0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        /// A procedure created without SPL retention has no stored text, which the server reports
        /// as an empty answer rather than an error.
        guard !text.isEmpty else {
            throw PluginObjectSourceError.insufficientPrivilege(routine.name)
        }
        return text
    }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await teradataTriggerList(schema: schema, table: nil)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let listed = try await teradataTriggerList(schema: trigger.schema, table: trigger.table)
        guard let definition = listed.first(where: { $0.name == trigger.name })?.definition,
              !definition.isEmpty
        else {
            throw PluginObjectSourceError.notFound(trigger.name)
        }
        return definition
    }

    func teradataTriggerList(schema: String?, table: String?) async throws -> [PluginTriggerInfo] {
        guard let database = routineDatabase(schema) else { return [] }
        let query = TeradataObjectQueries.triggerList(database: database, table: table)
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginTriggerInfo? in
            guard let name = cellText(row, 0)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                return nil
            }
            let definition = cellText(row, 7)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var attributes: [PluginObjectAttribute] = []
            if let order = cellText(row, 8)?.trimmingCharacters(in: .whitespaces), !order.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Order", value: order))
            }
            return PluginTriggerInfo(
                name: name,
                table: cellText(row, 2)?.trimmingCharacters(in: .whitespaces),
                schema: cellText(row, 1)?.trimmingCharacters(in: .whitespaces) ?? database,
                timing: TeradataObjectQueries.timing(fromActionTime: cellText(row, 3)),
                event: TeradataObjectQueries.event(fromEventCode: cellText(row, 4)),
                orientation: TeradataObjectQueries.orientation(fromKind: cellText(row, 5)),
                statement: definition ?? "",
                definition: definition,
                enabled: cellText(row, 6)?.trimmingCharacters(in: .whitespaces).uppercased() == "Y",
                attributes: attributes
            )
        }
    }

    private func routineDatabase(_ schema: String?) -> String? {
        if let schema, !schema.isEmpty { return schema }
        return currentDatabaseName
    }

    private func cellText(_ row: [PluginCellValue], _ index: Int) -> String? {
        guard index < row.count, case .text(let value) = row[index] else { return nil }
        return value
    }
}

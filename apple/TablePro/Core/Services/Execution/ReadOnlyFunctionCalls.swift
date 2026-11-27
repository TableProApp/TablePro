//
//  ReadOnlyFunctionCalls.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

// What Read-Only needs to know about a connection before it lets a read call a function.
internal struct ReadOnlyFunctionPolicy: Sendable, Equatable {
    // The live driver cannot run a statement in the engine's read-only mode, and a function on this engine can write.
    var functionsCanWrite = false
    // What holds the level up: a read-only engine or file, a configuration profile, Agent mode.
    var floor: SafeModeLevel?

    var levelThatRunsIt: SafeModeLevel? {
        SafeModeFloor.levelThatWrites(above: floor)
    }
}

// The Mac's reading of `SQLReadOnlyFunctionCalls`, with the engine's types from its plugin's dialect.
internal enum ReadOnlyFunctionCalls {
    static func builtins(for databaseType: DatabaseType) -> Set<String> {
        SQLReadOnlyFunctionCalls.builtins(forDatabaseTypeId: databaseType.rawValue)
    }

    static func callsUnlistedFunction(_ sql: String, databaseType: DatabaseType) -> Bool {
        SQLReadOnlyFunctionCalls.callsUnlistedFunction(
            sql,
            databaseTypeId: databaseType.rawValue,
            readings: databaseType.lexicalReadings,
            typeNames: Set(PluginMetadataRegistry.shared.snapshot(for: databaseType)?.editor.sqlDialect?.dataTypes ?? [])
        )
    }

    // Nil on an engine that calls a function only with parentheses.
    static func bareNameReading(_ sql: String, databaseType: DatabaseType) -> SQLBareNameReading? {
        guard SQLBareNameCalls.engines.contains(databaseType.rawValue) else { return nil }
        return SQLBareNameCalls.read(sql, databaseTypeId: databaseType.rawValue, readings: databaseType.lexicalReadings)
    }
}

// Export, Transfer To, Data Compare and Copy Objects read rows outside the editor, so text the user wrote into them, a
// row filter or the query an export runs again, meets the gate's Read-Only decision before any row is read.
internal enum ReadOnlyReadGate {
    @MainActor
    static func authorize(
        _ statements: [String],
        connectionId: UUID,
        databaseType: DatabaseType,
        gate: any ExecutionGate,
        operationDescription: String = String(localized: "Export"),
        canPrompt: Bool = true,
        manager: DatabaseManager? = nil,
        runsIn: DatabaseScope? = nil
    ) async throws {
        guard !statements.isEmpty, ExecutionGateProvider.runsAtReadOnly(connectionId, in: manager) else { return }
        let decision = await gate.authorize(
            OperationRequest(
                connectionId: connectionId,
                databaseType: databaseType,
                sql: statements.joined(separator: ";\n"),
                kind: .readQuery,
                caller: .userInterface,
                capabilities: canPrompt ? .interactiveUser : CallerCapabilities.interactiveUser.union(.cannotPrompt),
                operationDescription: operationDescription,
                statements: statements,
                runsIn: runsIn
            )
        )
        if let denial = decision.denialError { throw denial }
    }

    // The read each filtered object runs, in the form the gate reads it.
    static func rowScopeStatements(
        _ objects: [ExportObjectItem],
        databaseType: DatabaseType,
        quote: (String) -> String
    ) -> [String] {
        objects.compactMap { object in
            filterStatement(
                table: object.name,
                schema: object.databaseName,
                filter: object.rowScope.sanitizedFilter,
                databaseType: databaseType,
                quote: quote
            )
        }
    }

    static func filterStatement(
        table: String,
        schema: String?,
        filter: String?,
        databaseType: DatabaseType,
        quote: (String) -> String
    ) -> String? {
        guard let filter, !filter.isEmpty else { return nil }
        let name = SchemaQualifiedName.render(name: table, schema: schema, databaseType: databaseType, quote: quote)
        return "SELECT * FROM \(name) WHERE \(filter)"
    }
}

//
//  SchemaConnectionState.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
@Observable
final class SchemaConnectionState {
    private(set) var state: SchemaState = .idle
    private(set) var procedures: [RoutineInfo] = []
    private(set) var functions: [RoutineInfo] = []
    private(set) var schemasInOrder: [String] = []
    private(set) var perSchemaStates: [String: SchemaState] = [:]

    private(set) var tablesRevision = 0
    private(set) var routinesRevision = 0
    private(set) var schemasRevision = 0
    private(set) var perSchemaRevision = 0

    private let connectionId: UUID

    private static var registry: [UUID: SchemaConnectionState] = [:]

    private init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    static func forConnection(_ connectionId: UUID) -> SchemaConnectionState {
        if let existing = registry[connectionId] { return existing }
        let created = SchemaConnectionState(connectionId: connectionId)
        registry[connectionId] = created
        return created
    }

    static func removeConnection(_ connectionId: UUID) {
        registry.removeValue(forKey: connectionId)
    }

    var tables: [TableInfo] {
        if case .loaded(let tables) = state { return tables }
        return []
    }

    func tables(inSchema schema: String) -> [TableInfo] {
        if case .loaded(let tables) = perSchemaStates[schema] ?? .idle { return tables }
        return []
    }

    func perSchemaState(_ schema: String) -> SchemaState {
        perSchemaStates[schema] ?? .idle
    }

    var allLoadedTables: [TableInfo] {
        var result = tables
        var seen = Set(result.map(\.id))
        for state in perSchemaStates.values {
            guard case .loaded(let schemaTables) = state else { continue }
            for table in schemaTables where seen.insert(table.id).inserted {
                result.append(table)
            }
        }
        return result
    }

    func setState(_ newState: SchemaState) {
        state = newState
        tablesRevision &+= 1
        SidebarPerfSignpost.recordEvent("SchemaState.tables", connectionId: connectionId)
    }

    func setProcedures(_ routines: [RoutineInfo]) {
        procedures = routines
        routinesRevision &+= 1
        SidebarPerfSignpost.recordEvent("SchemaState.routines", connectionId: connectionId)
    }

    func setFunctions(_ routines: [RoutineInfo]) {
        functions = routines
        routinesRevision &+= 1
        SidebarPerfSignpost.recordEvent("SchemaState.routines", connectionId: connectionId)
    }

    func setSchemasInOrder(_ schemas: [String]) {
        schemasInOrder = schemas
        schemasRevision &+= 1
    }

    func clearSchemasInOrder() {
        guard !schemasInOrder.isEmpty else { return }
        schemasInOrder = []
        schemasRevision &+= 1
    }

    func setPerSchemaState(_ newState: SchemaState, schema: String) {
        perSchemaStates[schema] = newState
        perSchemaRevision &+= 1
    }

    func clearPerSchemaState(schema: String) {
        guard perSchemaStates[schema] != nil else { return }
        perSchemaStates.removeValue(forKey: schema)
        perSchemaRevision &+= 1
    }

    func loadedSchemaNames() -> [String] {
        Array(perSchemaStates.keys)
    }

    func reset() {
        state = .idle
        procedures = []
        functions = []
        schemasInOrder = []
        perSchemaStates = [:]
        tablesRevision &+= 1
        routinesRevision &+= 1
        schemasRevision &+= 1
        perSchemaRevision &+= 1
    }
}

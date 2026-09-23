//
//  SourceDefinitionStubDriver.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit

internal struct DefinitionReadStubError: LocalizedError {
    internal let message: String

    internal var errorDescription: String? { message }
}

internal final class SourceDefinitionStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    internal var viewDefinitions: [String: Result<String, any Error>] = [:]
    internal var routines: Result<[PluginRoutineInfo], any Error> = .success([])
    internal var routineDDL: [String: Result<String, any Error>] = [:]
    internal var wholeSchemaTriggers: Result<[PluginTriggerInfo], any Error>?
    internal var tableTriggers: [String: Result<[PluginTriggerInfo], any Error>] = [:]
    internal var triggerDDL: [String: Result<String, any Error>] = [:]

    internal var recordedCalls: [String] {
        lock.withLock { calls }
    }

    private func record(_ call: String) {
        lock.withLock { calls.append(call) }
    }

    internal var providesBulkTriggerFetch: Bool { wholeSchemaTriggers != nil }

    internal func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        record("fetchViewDefinition:\(view)")
        return try (viewDefinitions[view] ?? .success("")).get()
    }

    internal func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        record("fetchRoutines")
        return try routines.get()
    }

    internal func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        record("fetchRoutineDDL:\(routine.name)")
        return try (routineDDL[routine.name] ?? .failure(PluginObjectSourceError.unsupported(routine.name))).get()
    }

    internal func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        record("fetchAllTriggers")
        return try (wholeSchemaTriggers ?? .success([])).get()
    }

    internal func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        record("fetchTriggers:\(table)")
        return try (tableTriggers[table] ?? .success([])).get()
    }

    internal func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        record("fetchTriggerDDL:\(trigger.name)")
        return try (triggerDDL[trigger.name] ?? .failure(PluginObjectSourceError.notFound(trigger.name))).get()
    }

    internal func connect() async throws {}
    internal func disconnect() {}
    internal var isConnected: Bool { true }

    internal func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    internal func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    internal func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    internal func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    internal func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    internal func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }

    internal func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    internal func fetchDatabases() async throws -> [String] { [] }

    internal func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

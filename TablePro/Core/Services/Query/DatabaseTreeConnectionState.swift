//
//  DatabaseTreeConnectionState.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
@Observable
final class DatabaseTreeConnectionState {
    typealias DatabaseKey = DatabaseTreeMetadataService.DatabaseKey
    typealias ObjectsKey = DatabaseTreeMetadataService.ObjectsKey

    private(set) var databaseList: MetadataLoadState<[DatabaseMetadata]> = .idle
    private(set) var schemaList: [DatabaseKey: MetadataLoadState<[String]>] = [:]
    private(set) var tablesState: [ObjectsKey: MetadataLoadState<[TableInfo]>] = [:]
    private(set) var routinesState: [ObjectsKey: MetadataLoadState<[RoutineInfo]>] = [:]

    private static var registry: [UUID: DatabaseTreeConnectionState] = [:]

    static func forConnection(_ connectionId: UUID) -> DatabaseTreeConnectionState {
        if let existing = registry[connectionId] { return existing }
        let created = DatabaseTreeConnectionState()
        registry[connectionId] = created
        return created
    }

    static func removeConnection(_ connectionId: UUID) {
        registry.removeValue(forKey: connectionId)
    }

    func setDatabaseList(_ state: MetadataLoadState<[DatabaseMetadata]>) {
        databaseList = state
    }

    func setSchemaList(_ state: MetadataLoadState<[String]>, key: DatabaseKey) {
        schemaList[key] = state
    }

    func removeSchemaList(key: DatabaseKey) {
        schemaList.removeValue(forKey: key)
    }

    func setTablesState(_ state: MetadataLoadState<[TableInfo]>, key: ObjectsKey) {
        tablesState[key] = state
    }

    func removeTablesState(key: ObjectsKey) {
        tablesState.removeValue(forKey: key)
    }

    func setRoutinesState(_ state: MetadataLoadState<[RoutineInfo]>, key: ObjectsKey) {
        routinesState[key] = state
    }

    func removeRoutinesState(key: ObjectsKey) {
        routinesState.removeValue(forKey: key)
    }

    func reset() {
        databaseList = .idle
        schemaList = [:]
        tablesState = [:]
        routinesState = [:]
    }
}

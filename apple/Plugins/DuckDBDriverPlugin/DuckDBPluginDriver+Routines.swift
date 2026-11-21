//
//  DuckDBPluginDriver+Routines.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProDuckDBCore
import TableProPluginKit

nonisolated extension DuckDBPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        try await DuckDBExportCatalog.routines(catalog: try requireCatalog(), schema: schema, run: catalogRun)
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        try await DuckDBExportCatalog.routineDDL(routine, catalog: try requireCatalog(), run: catalogRun)
    }

    func generateDropRoutineSQL(name: String, signature: String?, schema: String?, isFunction: Bool) -> String? {
        DuckDBObjectQueries.dropMacro(name: name, schema: schema, isTableMacro: DuckDBObjectQueries.namesTableMacro(signature))
    }
}

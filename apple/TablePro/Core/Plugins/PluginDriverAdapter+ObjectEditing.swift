//
//  PluginDriverAdapter+ObjectEditing.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginDriverAdapter {
    // MARK: - Maintenance Operations

    func maintenanceOperations() -> [PluginMaintenanceOperation]? {
        pluginDriver.maintenanceOperations()
    }

    /// The session's own schema stands in only when the caller has none, so a command that does carry
    /// the object's schema qualifies with that one rather than with wherever the session points.
    func maintenanceStatements(
        operation: String,
        table: String?,
        schema: String?,
        options: [String: String]
    ) -> [String]? {
        pluginDriver.maintenanceStatements(
            operation: operation,
            table: table,
            schema: readSchema(schema),
            options: options
        )
    }

    // MARK: - Object Comments and Materialized Views

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        pluginDriver.objectCommentStatement(name: name, objectType: objectType, schema: schema, comment: comment)
    }

    func refreshMaterializedViewStatement(name: String, schema: String?, concurrently: Bool) -> String? {
        pluginDriver.refreshMaterializedViewStatement(name: name, schema: schema, concurrently: concurrently)
    }

    @concurrent
    func concurrentRefreshAvailability(
        materializedView: String,
        schema: String?
    ) async throws -> PluginConcurrentRefreshAvailability? {
        try await pluginDriver.concurrentRefreshAvailability(materializedView: materializedView, schema: schema)
    }

    @concurrent
    func fetchViewRowEditing(view: String, schema: String?) async throws -> PluginViewRowEditing? {
        try await pluginDriver.fetchViewRowEditing(view: view, schema: readSchema(schema))
    }

    @concurrent
    func primaryKeyNamesOneRow(inTable table: String, schema: String?) async throws -> Bool {
        guard primaryKeyNamesOneRow else { return false }
        return try await pluginDriver.primaryKeyNamesOneRow(table: table, schema: readSchema(schema))
    }

    // MARK: - Table Options

    @concurrent
    func fetchTableOptions(tableName: String, schema: String?) async throws -> TableOptions? {
        try await pluginDriver.fetchTableOptions(table: tableName, schema: readSchema(schema))
            .map(TableOptions.init)
    }

    @concurrent
    func fetchTableOptionsCatalog() async throws -> TableOptionsCatalog? {
        try await pluginDriver.fetchTableOptionsCatalog().map(TableOptionsCatalog.init)
    }

    @concurrent
    func fetchDefaultTableOptions(schema: String?) async throws -> TableOptions? {
        try await pluginDriver.fetchDefaultTableOptions(schema: readSchema(schema))
            .map(TableOptions.init)
    }

    func tableOptionsStatement(tableName: String, schema: String?, change: PluginTableOptionsChange) -> String? {
        pluginDriver.tableOptionsStatement(table: tableName, schema: schema, change: change)
    }

    // MARK: - Sequences

    @concurrent
    func fetchSequenceDetails(sequence: String, schema: String?) async throws -> PluginSequenceDetails? {
        try await pluginDriver.fetchSequenceDetails(sequence: sequence, schema: readSchema(schema))
    }

    func sequenceNextValueStatement(for sequence: PluginSequenceDetails, nextValue: PluginSequenceNextValue) -> String? {
        pluginDriver.sequenceNextValueStatement(for: sequence, nextValue: nextValue)
    }

    func alterSequenceStatement(for sequence: PluginSequenceDetails, settings: PluginSequenceSettings) -> String? {
        pluginDriver.alterSequenceStatement(for: sequence, settings: settings)
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        pluginDriver.createViewTemplate()
    }

    func createSequenceTemplate() -> String? {
        pluginDriver.createSequenceTemplate()
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        pluginDriver.editViewFallbackTemplate(viewName: viewName)
    }

    func castColumnToText(_ column: String) -> String {
        pluginDriver.castColumnToText(column)
    }
}

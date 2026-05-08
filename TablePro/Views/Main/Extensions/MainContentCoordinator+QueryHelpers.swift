//
//  MainContentCoordinator+QueryHelpers.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func resolveRowCap(sql: String, tabType: TabType) -> Int? {
        queryExecutionCoordinator.resolveRowCap(sql: sql, tabType: tabType)
    }

    func parseSchemaMetadata(_ schema: SchemaResult) -> ParsedSchemaMetadata {
        queryExecutionCoordinator.parseSchemaMetadata(schema)
    }

    func awaitSchemaResult(
        parallelTask: Task<SchemaResult, Error>?,
        tableName: String
    ) async -> SchemaResult? {
        await queryExecutionCoordinator.awaitSchemaResult(
            parallelTask: parallelTask,
            tableName: tableName
        )
    }

    func isMetadataCached(tabId: UUID, tableName: String) -> Bool {
        queryExecutionCoordinator.isMetadataCached(tabId: tabId, tableName: tableName)
    }

    func applyPhase1Result( // swiftlint:disable:this function_parameter_count
        tabId: UUID,
        columns: [String],
        columnTypes: [ColumnType],
        rows: [[String?]],
        executionTime: TimeInterval,
        rowsAffected: Int,
        statusMessage: String?,
        tableName: String?,
        isEditable: Bool,
        metadata: ParsedSchemaMetadata?,
        hasSchema: Bool,
        sql: String,
        connection conn: DatabaseConnection,
        isTruncated: Bool = false,
        queryParameterValues: [QueryParameter]? = nil
    ) {
        queryExecutionCoordinator.applyPhase1Result(
            tabId: tabId,
            columns: columns,
            columnTypes: columnTypes,
            rows: rows,
            executionTime: executionTime,
            rowsAffected: rowsAffected,
            statusMessage: statusMessage,
            tableName: tableName,
            isEditable: isEditable,
            metadata: metadata,
            hasSchema: hasSchema,
            sql: sql,
            connection: conn,
            isTruncated: isTruncated,
            queryParameterValues: queryParameterValues
        )
    }

    func launchPhase2Work(
        tableName: String,
        tabId: UUID,
        capturedGeneration: Int,
        connectionType: DatabaseType,
        schemaResult: SchemaResult?
    ) {
        queryExecutionCoordinator.launchPhase2Work(
            tableName: tableName,
            tabId: tabId,
            capturedGeneration: capturedGeneration,
            connectionType: connectionType,
            schemaResult: schemaResult
        )
    }

    func launchPhase2Count(
        tableName: String,
        tabId: UUID,
        capturedGeneration: Int,
        connectionType: DatabaseType
    ) {
        queryExecutionCoordinator.launchPhase2Count(
            tableName: tableName,
            tabId: tabId,
            capturedGeneration: capturedGeneration,
            connectionType: connectionType
        )
    }

    func handleQueryExecutionError(
        _ error: Error,
        sql: String,
        tabId: UUID,
        connection conn: DatabaseConnection
    ) {
        queryExecutionCoordinator.handleQueryExecutionError(
            error,
            sql: sql,
            tabId: tabId,
            connection: conn
        )
    }

    func restoreSchemaAndRunQuery(_ schema: String) async {
        await queryExecutionCoordinator.restoreSchemaAndRunQuery(schema)
    }

    func columnExclusions(for tableName: String) -> [ColumnExclusion] {
        queryExecutionCoordinator.columnExclusions(for: tableName)
    }
}

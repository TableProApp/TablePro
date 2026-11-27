//
//  PluginDriverAdapter+SchemaChangeChecks.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal extension PluginDriverAdapter {
    @concurrent
    func reviewSchemaChange(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation]
    ) async throws -> PluginSchemaChangeReview {
        try await pluginDriver.reviewSchemaChange(table: table, schema: schema, operations: operations)
    }

    @concurrent
    func schemaChangeRefusalBeforeWriting(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation],
        review: PluginSchemaChangeReview
    ) async throws -> String? {
        try await pluginDriver.schemaChangeRefusalBeforeWriting(
            table: table,
            schema: schema,
            operations: operations,
            review: review
        )
    }

    @concurrent
    func schemaChangeShortfallAfterWriting(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation],
        review: PluginSchemaChangeReview
    ) async throws -> String? {
        try await pluginDriver.schemaChangeShortfallAfterWriting(
            table: table,
            schema: schema,
            operations: operations,
            review: review
        )
    }

    func tableDefinitionDidChange(table: String, schema: String?) {
        pluginDriver.tableDefinitionDidChange(table: table, schema: schema)
    }
}

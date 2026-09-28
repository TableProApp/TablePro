//
//  PluginDriverAdapter+SchemaChangeChecks.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal extension PluginDriverAdapter {
    func reviewSchemaChange(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation]
    ) async throws -> PluginSchemaChangeReview {
        try await schemaPluginDriver.reviewSchemaChange(table: table, schema: schema, operations: operations)
    }

    func schemaChangeRefusalBeforeWriting(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation],
        review: PluginSchemaChangeReview
    ) async throws -> String? {
        try await schemaPluginDriver.schemaChangeRefusalBeforeWriting(
            table: table,
            schema: schema,
            operations: operations,
            review: review
        )
    }

    func schemaChangeShortfallAfterWriting(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation],
        review: PluginSchemaChangeReview
    ) async throws -> String? {
        try await schemaPluginDriver.schemaChangeShortfallAfterWriting(
            table: table,
            schema: schema,
            operations: operations,
            review: review
        )
    }

    func tableDefinitionDidChange(table: String, schema: String?) {
        schemaPluginDriver.tableDefinitionDidChange(table: table, schema: schema)
    }
}

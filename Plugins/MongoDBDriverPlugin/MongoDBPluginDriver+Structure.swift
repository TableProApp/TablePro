//
//  MongoDBPluginDriver+Structure.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

extension MongoDBPluginDriver {
    func generateModifyColumnSQL(
        table: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        let operation = PluginSchemaOperation.modifyColumn(old: oldColumn, new: newColumn)
        guard MongoFieldChange.refusal(for: operation) == nil, let change = MongoFieldChange(operation) else {
            return nil
        }
        return change.statement(collection: table, writeConcern: writeConcern)
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        guard columnName != MongoDBCollectionDDL.idField, MongoFieldName.addressingRefusal(columnName) == nil else {
            return nil
        }
        return MongoFieldChange.remove(columnName).statement(collection: table, writeConcern: writeConcern)
    }

    func reviewSchemaChange(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation]
    ) async throws -> PluginSchemaChangeReview {
        guard !MongoFieldChangePlan(operations: operations).isEmpty else { return PluginSchemaChangeReview() }
        return try await fieldChangeCheck(collection: table).review(operations: operations)
    }

    func schemaChangeRefusalBeforeWriting(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation],
        review: PluginSchemaChangeReview
    ) async throws -> String? {
        guard !MongoFieldChangePlan(operations: operations).isEmpty else { return nil }
        return try await fieldChangeCheck(collection: table).refusalBeforeWriting(operations: operations, review: review)
    }

    func schemaChangeShortfallAfterWriting(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation],
        review: PluginSchemaChangeReview
    ) async throws -> String? {
        guard !MongoFieldChangePlan(operations: operations).isEmpty else { return nil }
        return try await fieldChangeCheck(collection: table).shortfallAfterWriting(operations: operations, review: review)
    }

    /// The statements carry the write concern the connection's URI sets. A driver that has not
    /// connected composes nothing to run, since the review before it throws.
    private var writeConcern: MongoWriteConcern {
        mongoConnection?.configuredWriteConcern ?? .serverDefault
    }

    private func fieldChangeCheck(collection: String) throws -> MongoFieldChangeCheck {
        guard let connection = mongoConnection else { throw MongoDBPluginError.notConnected }
        return MongoFieldChangeCheck(connection: connection, database: currentDb, collection: collection)
    }
}

//
//  MongoDBPluginDriver+Documents.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

extension MongoDBPluginDriver {
    func documentWriteStatement(_ write: PluginDocumentWrite) throws -> String? {
        try documentWritePlan(write).statement
    }

    func executeDocumentWrite(_ write: PluginDocumentWrite) async throws {
        guard let conn = mongoConnection else { throw MongoDBPluginError.notConnected }
        let plan = try documentWritePlan(write)
        try await conn.insertDocument(database: currentDb, collection: write.table, document: plan.document)
    }

    private func documentWritePlan(_ write: PluginDocumentWrite) throws -> MongoDocumentWritePlan {
        guard let conn = mongoConnection else { throw MongoDBPluginError.notConnected }
        return try MongoDocumentWritePlan.make(
            collection: write.table,
            operation: write.operation,
            canonicalize: conn.canonicalDocument
        )
    }
}

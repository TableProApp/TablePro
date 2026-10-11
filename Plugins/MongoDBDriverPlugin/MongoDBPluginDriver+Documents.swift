//
//  MongoDBPluginDriver+Documents.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

extension MongoDBPluginDriver {
    func documentWriteStatement(_ write: PluginDocumentWrite) throws -> String? {
        try documentWritePlan(write)?.statement
    }

    /// The plan is built on a queue of its own, since an edit reads and compares the whole document
    /// and the caller may be the main actor.
    func executeDocumentWrite(_ write: PluginDocumentWrite) async throws {
        guard let conn = mongoConnection else { throw MongoDBPluginError.notConnected }
        let plan = try await pluginDispatchAsync(on: .global(qos: .userInitiated)) { [self] in
            try documentWritePlan(write)
        }
        guard let plan else { return }
        switch plan.write {
        case .insert(let document):
            try await conn.insertDocument(database: currentDb, collection: write.table, document: document)
        case .replace(let filter, let replacement):
            let matched = try await conn.replaceDocument(
                database: currentDb, collection: write.table, filter: filter, replacement: replacement
            )
            guard matched > 0 else { throw MongoDBDocumentEditingError.documentChanged }
        }
    }

    func fetchDocument(table: String, schema: String?, locator: String) async throws -> String? {
        guard let conn = mongoConnection else { throw MongoDBPluginError.notConnected }
        let identity = try MongoDocumentIdentity(locator: locator)
        let stored = try await conn.readStoredDocuments(database: currentDb, collection: table, identity: identity)
        try Task.checkCancellation()
        return try await pluginDispatchAsync(on: .global(qos: .userInitiated)) {
            try MongoEditableDocument.text(for: identity, among: stored, codec: MongoLibbsonCodec())
        }
    }

    private func documentWritePlan(_ write: PluginDocumentWrite) throws -> MongoDocumentWritePlan? {
        guard let conn = mongoConnection else { throw MongoDBPluginError.notConnected }
        return try MongoDocumentWritePlan.make(
            collection: write.table,
            operation: write.operation,
            canonicalize: conn.canonicalDocument
        )
    }
}

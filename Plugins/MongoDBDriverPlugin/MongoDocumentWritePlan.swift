//
//  MongoDocumentWritePlan.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

/// What Insert Document sends, and the shell statement that says so.
///
/// The statement is what the execution gate shows and query history keeps. The write itself goes
/// to libmongoc with the same document, so the two cannot disagree about what was sent.
struct MongoDocumentWritePlan: Equatable, Sendable {
    let document: String
    let statement: String

    /// - Parameter canonicalize: libbson's reading of a text as canonical Extended JSON. It is
    ///   passed in so the plan can be built without a connection.
    static func make(
        collection: String,
        operation: PluginDocumentWrite.Operation,
        canonicalize: (String) throws -> String
    ) throws -> MongoDocumentWritePlan {
        switch operation {
        case .insert(let text):
            let document = try canonicalDocument(text, canonicalize: canonicalize).compactText
            let accessor = MongoCollectionAccessor.expression(for: collection)
            return MongoDocumentWritePlan(document: document, statement: "\(accessor).insertOne(\(document))")
        @unknown default:
            throw MongoDBDocumentEditingError.unsupportedOperation
        }
    }

    /// Read strictly first, because libbson accepts text that is not one document, then by libbson,
    /// because only it knows which Extended JSON wrappers it can turn into BSON.
    private static func canonicalDocument(
        _ text: String,
        canonicalize: (String) throws -> String
    ) throws -> MongoDocumentText {
        _ = try MongoDocumentText(parsing: text)
        return try MongoDocumentText(parsing: try canonicalize(text))
    }
}

enum MongoDBDocumentEditingError: Error, Equatable, LocalizedError {
    case unsupportedOperation

    var errorDescription: String? {
        switch self {
        case .unsupportedOperation:
            return String(localized: "MongoDB cannot make this change to a document.")
        }
    }
}

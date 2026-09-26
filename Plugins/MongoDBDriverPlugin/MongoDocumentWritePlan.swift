//
//  MongoDocumentWritePlan.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

/// What Insert Document and Edit Document send, and the shell statement that says so.
///
/// The statement is what the execution gate shows and query history keeps. The write itself goes
/// to libmongoc with the same documents, so the two cannot disagree about what was sent.
struct MongoDocumentWritePlan: Equatable, Sendable {
    enum Write: Equatable, Sendable {
        case insert(document: String)
        case replace(filter: String, replacement: String)
    }

    /// Written into the statement because the replace runs under it: only the simple collation
    /// compares strings byte for byte, which is what makes the guard exact.
    static let replaceOptions = #"{"collation":{"locale":"simple"}}"#

    let write: Write
    let statement: String

    /// Nil when an edit changes nothing, so there is nothing to write.
    ///
    /// - Parameter canonicalize: libbson's reading of a text as canonical Extended JSON. It is
    ///   passed in so the plan can be built without a connection.
    static func make(
        collection: String,
        operation: PluginDocumentWrite.Operation,
        canonicalize: (String) throws -> String
    ) throws -> MongoDocumentWritePlan? {
        let accessor = MongoCollectionAccessor.expression(for: collection)
        switch operation {
        case .insert(let text):
            let document = try canonicalDocument(text, canonicalize: canonicalize).compactText
            return MongoDocumentWritePlan(write: .insert(document: document), statement: "\(accessor).insertOne(\(document))")
        case .replace(let originalText, let editedText):
            let original = try canonicalDocument(originalText, canonicalize: canonicalize)
            let edited = try canonicalDocument(editedText, canonicalize: canonicalize)
            let replacement = try MongoDocumentReplacement(original: original, edited: edited)
            guard replacement.changesDocument else { return nil }
            let filter = try MongoDocumentGuard.filter(for: original)
            let document = replacement.document.compactText
            return MongoDocumentWritePlan(
                write: .replace(filter: filter, replacement: document),
                statement: "\(accessor).replaceOne(\(filter), \(document), \(replaceOptions))"
            )
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

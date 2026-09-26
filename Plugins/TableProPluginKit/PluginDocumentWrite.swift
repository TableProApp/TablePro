//
//  PluginDocumentWrite.swift
//  TableProPluginKit
//

import Foundation

/// A whole document the user wrote, for an engine that stores documents rather than rows.
///
/// A row is addressed column by column, and the columns of a document store are whatever fields the
/// documents it sampled happened to have. A collection with no documents has no column a new field
/// could be typed into, so a document is written whole instead, as the text the user edited.
///
/// Non-frozen, so both the write and its operation can gain a field or a case later. The text is the engine's own document
/// syntax, Extended JSON for MongoDB, and the driver is the only thing that reads it.
public struct PluginDocumentWrite: Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        case insert(document: String)
        /// Replaces a stored document with `edited`. `original` is the text `fetchDocument`
        /// returned: it names the document and is what the edit is compared against, so a document
        /// someone changed after it was fetched is refused rather than overwritten.
        case replace(original: String, edited: String)
    }

    public let table: String
    public let schema: String?
    public let operation: Operation

    public init(table: String, schema: String?, operation: Operation) {
        self.table = table
        self.schema = schema
        self.operation = operation
    }
}

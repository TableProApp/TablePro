//
//  MongoDBFieldKinds.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

/// Every kind of value each top-level field held in the documents the grid was handed.
///
/// A cell shows a document and a string that reads the same as the same text, and the majority
/// kind a column is typed by says nothing about one row. A field that has held documents and no
/// strings shows a document in every cell that opens with `{`; one that has held both cannot say
/// which a cell holds. Added to rather than replaced, like the binary subtypes, so a string read on
/// an earlier page is not forgotten when a later page holds only documents.
struct MongoDBFieldKinds: Sendable {
    private var kindsByField: [String: Set<BsonValueKind>]

    static let empty = MongoDBFieldKinds([:])

    /// Past this many fields a collection records no new ones, and a field it never recorded is
    /// treated as unknown rather than as holding one kind.
    static let fieldLimit = 10_000

    init(_ kindsByField: [String: Set<BsonValueKind>]) {
        self.kindsByField = kindsByField
    }

    static func recording(_ documents: [[String: Any]], representation: MongoDBUuidRepresentation) -> MongoDBFieldKinds {
        MongoDBFieldKinds(BsonDocumentFlattener.heldKinds(in: documents, representation: representation))
    }

    var isEmpty: Bool { kindsByField.isEmpty }

    /// The kinds the field was seen holding, or nil when it was never seen.
    func kinds(of field: String) -> Set<BsonValueKind>? {
        kindsByField[field]
    }

    func merging(_ other: MongoDBFieldKinds) -> MongoDBFieldKinds {
        var merged = self
        for (field, kinds) in other.kindsByField {
            guard merged.kindsByField[field] != nil || merged.kindsByField.count < Self.fieldLimit else { continue }
            merged.kindsByField[field, default: []].formUnion(kinds)
        }
        return merged
    }
}

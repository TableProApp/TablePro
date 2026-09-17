//
//  WeaviateOperations.swift
//  TableProWeaviateCore
//

import Foundation

public enum WeaviateOperations {
    /// The console request that removes one collection, in the text `WeaviateConsoleParser` reads.
    ///
    /// Plain console text rather than the tagged write form, because the confirmation dialog shows
    /// the statement verbatim and `QueryClassifier` reads the leading verb to tier it destructive.
    /// What the user approves, what the gate classifies and what runs are then one string.
    public static func deleteCollection(named name: String, objectType: String) -> String? {
        guard isCollectionObject(objectType), isClassName(name) else { return nil }
        return "DELETE /v1/schema/\(name)"
    }

    public static let exportTag = "WEAVIATE_EXPORT:"

    /// The statement Export asks the driver for, naming one collection and nothing else.
    ///
    /// A tag rather than a browse query, because a browse query carries a `limit` that would cap
    /// the export. `streamRows` decodes this and walks the collection a page at a time, yielding
    /// each one, so a large collection never has to fit in memory at once. Without it the app
    /// fabricates `SELECT * FROM "<collection>"`, which this driver has no parser for.
    public static func encodeExport(collection: String) -> String {
        "\(exportTag)\(Data(collection.utf8).base64EncodedString())"
    }

    public static func decodeExport(_ query: String) -> String? {
        guard query.hasPrefix(exportTag),
              let data = Data(base64Encoded: String(query.dropFirst(exportTag.count))),
              let collection = String(data: data, encoding: .utf8),
              !collection.isEmpty
        else { return nil }
        return collection
    }

    /// Weaviate has only collections, so any other kind the app asks about is not something this
    /// engine drops, and answering anyway would delete the collection of that name instead.
    public static func isCollectionObject(_ objectType: String) -> Bool {
        objectType.uppercased() == "TABLE"
    }

    /// A Weaviate class name is a GraphQL identifier. A name holding anything else did not come
    /// from the schema listing, so it is refused rather than pasted into the request path.
    public static func isClassName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

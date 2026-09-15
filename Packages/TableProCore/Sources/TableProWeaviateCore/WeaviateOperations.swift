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

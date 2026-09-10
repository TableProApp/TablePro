//
//  TypesenseOperations.swift
//  TypesenseDriverPlugin
//
//  Collection-level operations the app asks for in SQL: export, drop, truncate and maintenance.
//

import Foundation

/// The app builds `SELECT * FROM t`, `DROP TABLE t` and `DELETE FROM t` whenever a driver declines
/// to spell those itself, and sends them to `execute`. Typesense understands none of them, so each
/// one has to come back as a request it does understand or the feature is dead on arrival.
enum TypesenseOperations {
    /// Export streams rather than executes, so it carries its own tag: `streamRows` recognises it
    /// and reads the collection's JSONL endpoint instead of paging through search results.
    static let exportTag = "TYPESENSE_EXPORT:"

    static let compactOperation = "Compact Database"

    // MARK: - Export

    static func encodeExport(collection: String) -> String {
        "\(exportTag)\(Data(collection.utf8).base64EncodedString())"
    }

    static func decodeExport(_ query: String) -> String? {
        guard query.hasPrefix(exportTag),
              let data = Data(base64Encoded: String(query.dropFirst(exportTag.count))),
              let collection = String(data: data, encoding: .utf8),
              !collection.isEmpty
        else { return nil }
        return collection
    }

    static func exportPath(collection: String) -> String {
        "/collections/\(TypesensePathEncoding.segment(collection))/documents/export"
    }

    // MARK: - Collection Operations

    /// Only a collection can be dropped. Typesense has no databases, views or schemas, so an
    /// object type naming one of those has no request behind it and the app keeps its own fallback.
    static func dropCollection(named name: String, objectType: String) -> TypesenseWriteRequest? {
        guard isCollectionObject(objectType) else { return nil }
        return TypesenseWriteRequest(
            method: "DELETE",
            path: "/collections/\(TypesensePathEncoding.segment(name))",
            body: nil
        )
    }

    /// `truncate=true` empties the collection and keeps its schema, which is what TRUNCATE means.
    /// Deleting by a match-everything filter would drop the schema's learned fields with it.
    static func truncateCollection(named name: String) -> TypesenseWriteRequest {
        TypesenseWriteRequest(
            method: "DELETE",
            path: "/collections/\(TypesensePathEncoding.segment(name))/documents?truncate=true",
            body: nil
        )
    }

    /// Compaction is deliberately not published through `supportedMaintenanceOperations`. Both of
    /// the app's maintenance surfaces are scoped to the selected table, and this one compacts the
    /// whole database, so listing it there would offer a per-collection item that silently acts on
    /// everything. It stays reachable in the console, where the path says what it does.
    static func maintenance(_ operation: String) -> TypesenseWriteRequest? {
        guard operation.caseInsensitiveCompare(compactOperation) == .orderedSame else { return nil }
        return TypesenseWriteRequest(method: "POST", path: "/operations/db/compact", body: nil)
    }

    private static func isCollectionObject(_ objectType: String) -> Bool {
        let upper = objectType.uppercased()
        return upper.isEmpty || upper == "TABLE" || upper == "COLLECTION"
    }
}

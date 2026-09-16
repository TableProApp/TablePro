//
//  ElasticsearchOperations.swift
//  ElasticsearchDriverPlugin
//
//  The object operations the app offers, as the console requests the driver already runs.
//

import Foundation

enum ElasticsearchOperations {
    /// The request that deletes one index, in the console's own text.
    ///
    /// Plain `DELETE /<index>` rather than the tagged, base64 form `ElasticsearchStatementGenerator`
    /// uses for row writes, and deliberately: the confirmation dialog shows the statement verbatim,
    /// so the tagged form would ask the user to approve unreadable base64, and `QueryClassifier`
    /// reads the leading verb to tier a statement as destructive. The console parser accepts this,
    /// so what is shown, what is classified and what runs are the same string.
    static func deleteIndex(named name: String, objectType: String) -> String? {
        guard isIndexObject(objectType), let path = singleIndexPath(name) else { return nil }
        return "DELETE \(path)"
    }

    static let exportTag = "ELASTICSEARCH_EXPORT:"

    /// The statement Export asks the driver for, naming one index and nothing else.
    ///
    /// A tag rather than a console request, because Export must read the whole index and a console
    /// request carries a `size` that would cap it. `streamRows` decodes this and pages with a
    /// point-in-time and `search_after`, yielding each batch, so a large index never has to fit in
    /// memory at once. Without it the app fabricates `SELECT * FROM "<index>"`, which this driver
    /// answers with "Enter a request like: GET /my-index/_search" and the file comes out empty.
    static func encodeExport(index: String) -> String {
        "\(exportTag)\(Data(index.utf8).base64EncodedString())"
    }

    static func decodeExport(_ query: String) -> String? {
        guard query.hasPrefix(exportTag),
              let data = Data(base64Encoded: String(query.dropFirst(exportTag.count))),
              let index = String(data: data, encoding: .utf8),
              !index.isEmpty
        else { return nil }
        return index
    }

    /// Only an index. Elasticsearch has no views or materialized views, so anything else the app
    /// asks about is not something this engine can drop.
    static func isIndexObject(_ objectType: String) -> Bool {
        objectType.uppercased() == "TABLE"
    }

    /// The path for exactly one index, or nil where the name could name more than one.
    ///
    /// `DELETE /<target>` takes a comma-separated list and wildcards, and a cluster that has turned
    /// `action.destructive_requires_name` off will act on every match, so `DELETE /*` empties it.
    /// A real index name can hold none of these characters, so refusing them costs nothing and
    /// means a name that arrived from somewhere other than the index listing cannot widen the
    /// request.
    static func singleIndexPath(_ name: String) -> String? {
        guard !name.isEmpty, name != "_all", !name.hasPrefix("-") else { return nil }
        guard name.rangeOfCharacter(from: forbiddenInSingleIndex) == nil else { return nil }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: pathComponentAllowed) ?? name
        return "/\(encoded)"
    }

    private static let forbiddenInSingleIndex = CharacterSet(charactersIn: "*,?/\\<>|\"# ")
        .union(.whitespacesAndNewlines)

    private static let pathComponentAllowed: CharacterSet =
        .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
}

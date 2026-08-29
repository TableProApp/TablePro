import Foundation

/// Builds the database commands a script's collection methods stand for.
///
/// Writes go out as commands rather than through the collection convenience calls so the whole
/// server reply is available: `n`, `nModified` and `upserted` are what a mongosh result object is
/// made of, and the convenience calls report only one of them.
enum MongoScriptCommandBuilder {
    enum BulkKind {
        case insert
        case update
        case delete
    }

    struct BulkStatement {
        let kind: BulkKind
        let document: String
    }

    static func update(
        collection: String,
        filter: String,
        update: String,
        multi: Bool,
        options: [String: Any]
    ) -> String {
        var fields = [
            "\"q\": \(filter)",
            "\"u\": \(update)",
            "\"multi\": \(multi)",
            "\"upsert\": \(options["upsert"] as? Bool ?? false)"
        ]
        appendPassThrough(&fields, options: options, keys: ["arrayFilters", "hint", "collation"])
        return """
            {"update": \(MongoScriptJson.jsonString(collection)), "updates": [{\(fields.joined(separator: ", "))}]}
            """
    }

    static func delete(collection: String, filter: String, multi: Bool, options: [String: Any]) -> String {
        var fields = ["\"q\": \(filter)", "\"limit\": \(multi ? 0 : 1)"]
        appendPassThrough(&fields, options: options, keys: ["hint", "collation"])
        return """
            {"delete": \(MongoScriptJson.jsonString(collection)), "deletes": [{\(fields.joined(separator: ", "))}]}
            """
    }

    static func findAndModify(
        collection: String,
        filter: String,
        update: String?,
        remove: Bool,
        options: [String: Any]
    ) -> String {
        var fields = [
            "\"findAndModify\": \(MongoScriptJson.jsonString(collection))",
            "\"query\": \(filter)"
        ]
        if remove {
            fields.append("\"remove\": true")
        } else if let update {
            fields.append("\"update\": \(update)")
            fields.append("\"new\": \(returnsUpdatedDocument(options))")
            fields.append("\"upsert\": \(options["upsert"] as? Bool ?? false)")
        }
        appendPassThrough(&fields, options: options, keys: ["sort", "arrayFilters", "hint", "collation"])
        if let projection = jsonText(options["projection"]) {
            fields.append("\"fields\": \(projection)")
        }
        return "{\(fields.joined(separator: ", "))}"
    }

    static func createIndex(collection: String, keys: String, options: [String: Any]) -> String {
        var fields = ["\"key\": \(keys)", "\"name\": \(MongoScriptJson.jsonString(indexName(keys: keys, options: options)))"]
        appendPassThrough(
            &fields,
            options: options,
            keys: [
                "unique", "sparse", "expireAfterSeconds", "partialFilterExpression",
                "collation", "background", "hidden", "weights", "default_language"
            ]
        )
        return """
            {"createIndexes": \(MongoScriptJson.jsonString(collection)), \
            "indexes": [{\(fields.joined(separator: ", "))}]}
            """
    }

    static func find(
        collection: String,
        filter: String,
        options: MongoScriptCursorOptions,
        ceiling: Int
    ) -> String {
        var fields = [
            "\"find\": \(MongoScriptJson.jsonString(collection))",
            "\"filter\": \(filter)",
            "\"limit\": \(options.effectiveLimit(ceiling: ceiling))"
        ]
        if let sort = options.sort { fields.append("\"sort\": \(sort)") }
        if let projection = options.projection { fields.append("\"projection\": \(projection)") }
        if let skip = options.skip, skip > 0 { fields.append("\"skip\": \(skip)") }
        if let hint = options.hint { fields.append("\"hint\": \(hint)") }
        if let collation = options.collation { fields.append("\"collation\": \(collation)") }
        if let batchSize = options.batchSize { fields.append("\"batchSize\": \(batchSize)") }
        if let maxTimeMS = options.maxTimeMS { fields.append("\"maxTimeMS\": \(maxTimeMS)") }
        if options.allowDiskUse { fields.append("\"allowDiskUse\": true") }
        return "{\(fields.joined(separator: ", "))}"
    }

    static func aggregate(collection: String, pipeline: String, options: MongoScriptCursorOptions) -> String {
        var fields = [
            "\"aggregate\": \(MongoScriptJson.jsonString(collection))",
            "\"pipeline\": \(options.decoratedPipeline(pipeline))",
            "\"cursor\": {}"
        ]
        if let hint = options.hint { fields.append("\"hint\": \(hint)") }
        if let collation = options.collation { fields.append("\"collation\": \(collation)") }
        if options.allowDiskUse { fields.append("\"allowDiskUse\": true") }
        if let maxTimeMS = options.maxTimeMS { fields.append("\"maxTimeMS\": \(maxTimeMS)") }
        return "{\(fields.joined(separator: ", "))}"
    }

    static func bulkOperation(_ operation: String, collection: String) throws -> BulkStatement {
        if let document = MongoScriptJson.member(of: operation, key: "insertOne") {
            let payload = MongoScriptJson.member(of: document, key: "document") ?? "{}"
            return BulkStatement(
                kind: .insert,
                document: """
                    {"insert": \(MongoScriptJson.jsonString(collection)), "documents": [\(payload)]}
                    """
            )
        }
        for name in ["updateOne", "updateMany", "replaceOne"] {
            guard let body = MongoScriptJson.member(of: operation, key: name) else { continue }
            let filter = MongoScriptJson.member(of: body, key: "filter") ?? "{}"
            let change = MongoScriptJson.member(of: body, key: name == "replaceOne" ? "replacement" : "update")
            return BulkStatement(
                kind: .update,
                document: update(
                    collection: collection,
                    filter: filter,
                    update: change ?? "{}",
                    multi: name == "updateMany",
                    options: MongoScriptJson.options(body)
                )
            )
        }
        for name in ["deleteOne", "deleteMany"] {
            guard let body = MongoScriptJson.member(of: operation, key: name) else { continue }
            return BulkStatement(
                kind: .delete,
                document: delete(
                    collection: collection,
                    filter: MongoScriptJson.member(of: body, key: "filter") ?? "{}",
                    multi: name == "deleteMany",
                    options: [:]
                )
            )
        }
        throw MongoScriptError(MongoScriptText.unsupportedBulkOperation(operation))
    }

    // MARK: - Helpers

    /// The name MongoDB gives an index the script did not name, which is the key names and their
    /// directions joined with underscores, in the order the key document declares them.
    static func indexName(keys: String, options: [String: Any]) -> String {
        if let named = options["name"] as? String, !named.isEmpty { return named }
        let parts = MongoScriptJson.members(of: keys).map { member -> String in
            "\(member.key)_\(direction(of: member.value))"
        }
        return parts.isEmpty ? "index" : parts.joined(separator: "_")
    }

    private static func direction(of valueJson: String) -> String {
        let trimmed = valueJson.trimmingCharacters(in: .whitespaces)
        if let literal = Int(trimmed) { return String(literal) }
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let number = MongoScriptJson.numeric(parsed) else { return "1" }
        return String(number)
    }

    private static func returnsUpdatedDocument(_ options: [String: Any]) -> Bool {
        if let flag = options["returnNewDocument"] as? Bool { return flag }
        if let document = options["returnDocument"] as? String { return document.lowercased() == "after" }
        if let flag = options["new"] as? Bool { return flag }
        return false
    }

    private static func appendPassThrough(_ fields: inout [String], options: [String: Any], keys: [String]) {
        for key in keys {
            guard let text = jsonText(options[key]) else { continue }
            fields.append("\"\(key)\": \(text)")
        }
    }

    private static func jsonText(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        if let text = value as? String { return MongoScriptJson.jsonString(text) }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

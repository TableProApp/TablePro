import Foundation

/// Builds the database commands a script's collection methods stand for.
///
/// Updates and deletes go out as commands rather than through libmongoc's collection calls, for
/// two reasons measured against libmongoc 1.28.1. The collection calls make the caller choose
/// between an update and a replacement and check the keys first, where a legacy
/// `update(filter, document)` leaves that to the server. And the Bulk API refuses `maxTimeMS` as an
/// option, which is how the query timeout reaches a write.
///
/// `mongoc_client_command_simple` applies no write concern to a command, so every write command
/// carries the one `writeConcern(statementOptions:connectionDefault:)` resolves, the way mongosh
/// does: the statement's own if it names one, otherwise the connection's.
///
/// A statement's write concern is rebuilt from the names the server reads rather than passed on as
/// written. mongosh takes `journal` and `wtimeoutMS` beside `j` and `wtimeout`, and `fsync` for
/// `j`. MongoDB 7.0.43 refuses a command whose write concern carries any other name
/// (`IDLUnknownField`), and libmongoc 1.28.1 drops those names from an insert's options along with
/// the connection's own write concern, so the insert goes out with neither.
enum MongoScriptCommandBuilder {
    struct BulkStatement {
        let kind: MongoWriteOperation
        let touchesMany: Bool
        let document: String
    }

    /// The statement's write concern if it names one, otherwise the connection's.
    ///
    /// A write concern that names none of `w`, `j` and `wtimeout`, in any spelling, counts as unset,
    /// as mongosh treats it: `{}` falls back to the connection's rather than dropping it. One that
    /// names any of them replaces the connection's whole, again as in mongosh.
    static func writeConcern(statementOptions: String?, connectionDefault: String?) -> String? {
        statementWriteConcern(statementOptions) ?? connectionDefault
    }

    /// The options the insert call takes from the statement. The connection's write concern is not
    /// among them: the collection inherits it from the client, and libmongoc lets the statement's
    /// own win.
    static func insertOptions(statementOptions: String?) -> String? {
        guard let statementOptions else { return nil }
        let fields = [
            insertWriteConcern(statementOptions).map { "\"writeConcern\": \($0)" },
            presentMember(of: statementOptions, key: "ordered").map { "\"ordered\": \($0)" }
        ].compactMap { $0 }
        return fields.isEmpty ? nil : "{\(fields.joined(separator: ", "))}"
    }

    /// Whether the server answers a write sent with this write concern.
    ///
    /// Measured on MongoDB 7.0.43: with `w: 0` and no `j: true`, an insert, update or delete command
    /// is answered with `n: 0` whatever it changed, and a duplicate key or an immutable `_id` it
    /// hit is not reported at all. With `j: true` beside `w: 0` it is answered in full, which is also
    /// what libmongoc's own `mongoc_write_concern_is_acknowledged` says. libmongoc sends an insert
    /// with `w: -1`, its legacy value for ignoring errors, without waiting for an answer, and the
    /// server drops that insert, since it refuses a `w` below 0.
    static func isAcknowledged(writeConcern: String?) -> Bool {
        guard let writeConcern, let w = numericW(of: writeConcern), w <= 0 else { return true }
        return presentMember(of: writeConcern, key: "j") == "true"
    }

    static func update(
        collection: String,
        filter: String,
        update: String,
        multi: Bool,
        options: [String: Any],
        writeConcern: String?
    ) -> String {
        var fields = [
            "\"q\": \(filter)",
            "\"u\": \(update)",
            "\"multi\": \(multi)",
            "\"upsert\": \(options["upsert"] as? Bool ?? false)"
        ]
        appendPassThrough(&fields, options: options, keys: ["arrayFilters", "hint", "collation"])
        return command(
            ["\"update\": \(MongoScriptJson.jsonString(collection))", "\"updates\": [{\(fields.joined(separator: ", "))}]"],
            writeConcern: writeConcern
        )
    }

    static func delete(
        collection: String,
        filter: String,
        multi: Bool,
        options: [String: Any],
        writeConcern: String?
    ) -> String {
        var fields = ["\"q\": \(filter)", "\"limit\": \(multi ? 0 : 1)"]
        appendPassThrough(&fields, options: options, keys: ["hint", "collation"])
        return command(
            ["\"delete\": \(MongoScriptJson.jsonString(collection))", "\"deletes\": [{\(fields.joined(separator: ", "))}]"],
            writeConcern: writeConcern
        )
    }

    static func findAndModify(
        collection: String,
        filter: String,
        update: String?,
        remove: Bool,
        options: [String: Any],
        writeConcern: String?
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
        return command(fields, writeConcern: writeConcern)
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

    static func bulkOperation(_ operation: String, collection: String, writeConcern: String?) throws -> BulkStatement {
        if let document = MongoScriptJson.member(of: operation, key: "insertOne") {
            let payload = MongoScriptJson.member(of: document, key: "document") ?? "{}"
            return BulkStatement(
                kind: .insert,
                touchesMany: false,
                document: command(
                    ["\"insert\": \(MongoScriptJson.jsonString(collection))", "\"documents\": [\(payload)]"],
                    writeConcern: writeConcern
                )
            )
        }
        for name in ["updateOne", "updateMany", "replaceOne"] {
            guard let body = MongoScriptJson.member(of: operation, key: name) else { continue }
            let filter = MongoScriptJson.member(of: body, key: "filter") ?? "{}"
            let change = MongoScriptJson.member(of: body, key: name == "replaceOne" ? "replacement" : "update")
            return BulkStatement(
                kind: .update,
                touchesMany: name == "updateMany",
                document: update(
                    collection: collection,
                    filter: filter,
                    update: change ?? "{}",
                    multi: name == "updateMany",
                    options: MongoScriptJson.options(body),
                    writeConcern: writeConcern
                )
            )
        }
        for name in ["deleteOne", "deleteMany"] {
            guard let body = MongoScriptJson.member(of: operation, key: name) else { continue }
            return BulkStatement(
                kind: .delete,
                touchesMany: name == "deleteMany",
                document: delete(
                    collection: collection,
                    filter: MongoScriptJson.member(of: body, key: "filter") ?? "{}",
                    multi: name == "deleteMany",
                    options: MongoScriptJson.options(body),
                    writeConcern: writeConcern
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

    private static func command(_ fields: [String], writeConcern: String?) -> String {
        guard let writeConcern else { return "{\(fields.joined(separator: ", "))}" }
        return "{\((fields + ["\"writeConcern\": \(writeConcern)"]).joined(separator: ", "))}"
    }

    private typealias ConcernField = (name: String, value: String)

    private static func statementWriteConcern(_ statementOptions: String?) -> String? {
        statementConcernFields(statementOptions).map(concernDocument)
    }

    /// The statement's write concern as the insert call can take it.
    ///
    /// libmongoc 1.28.1 refuses `j: true` beside `w: 0` for an insert (`Invalid writeConcern`). The
    /// server answers that pair in full and waits for the journal, as it does for `w: 1, j: true`:
    /// it leaves out the reply only for a `w` below 1 with neither `j` nor `fsync`. So the insert
    /// goes out with `w: 1`, which is what `isAcknowledged` already says the pair means.
    private static func insertWriteConcern(_ statementOptions: String) -> String? {
        guard let fields = statementConcernFields(statementOptions) else { return nil }
        let concern = concernDocument(fields)
        guard numericW(of: concern) == 0, presentMember(of: concern, key: "j") == "true" else { return concern }
        return concernDocument(fields.map { $0.name == "w" ? (name: "w", value: "1") : $0 })
    }

    /// The statement's write concern under the names the server reads, or nil when it names none.
    ///
    /// Each name takes the first spelling the statement set, in the order mongosh reads them:
    /// `j`, then `journal`, then `fsync`, and `wtimeout`, then `wtimeoutMS`.
    private static func statementConcernFields(_ statementOptions: String?) -> [ConcernField]? {
        guard let concern = statementOptions.flatMap({ presentMember(of: $0, key: "writeConcern") }) else {
            return nil
        }
        let spellings = [("w", ["w"]), ("j", ["j", "journal", "fsync"]), ("wtimeout", ["wtimeout", "wtimeoutMS"])]
        let fields = spellings.compactMap { name, keys -> ConcernField? in
            keys.lazy.compactMap { presentMember(of: concern, key: $0) }.first.map { (name: name, value: $0) }
        }
        return fields.isEmpty ? nil : fields
    }

    private static func concernDocument(_ fields: [ConcernField]) -> String {
        "{\(fields.map { "\"\($0.name)\": \($0.value)" }.joined(separator: ", "))}"
    }

    /// The write concern's `w` when it is a number rather than `"majority"` or a tag.
    private static func numericW(of concern: String) -> Int64? {
        guard let w = presentMember(of: concern, key: "w"), w != "true", w != "false" else { return nil }
        return MongoScriptJson.number(in: concern, key: "w")
    }

    /// A member the statement set, where `null` counts as not set, as it does in mongosh: sending it
    /// on makes the server refuse the whole command.
    private static func presentMember(of json: String, key: String) -> String? {
        guard let value = MongoScriptJson.member(of: json, key: key), value != "null" else { return nil }
        return value
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

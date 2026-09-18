import Foundation
import TableProPluginKit
import os

/// The one entry point JavaScript has into the driver.
///
/// Every call from the prelude arrives here as a JSON request and leaves as a JSON response, so the
/// bridge is a single function rather than a bridged object graph. Values cross as Extended JSON in
/// both directions and are spliced into command documents as text, never rebuilt through
/// `JSONSerialization`, because a document round-tripped through a Swift dictionary comes back with
/// its fields in another order and BSON field order is part of the document.
final class MongoScriptHost {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MongoScriptHost")
    private static let pageSize = 1_000
    private static let retainedCursors = 64

    private let connection: MongoDBConnection
    private let cursors = MongoScriptCursorRegistry()
    private let activityLock = NSLock()
    private var activity = Date()
    private var cancelled = false
    private(set) var database: String
    private(set) var printedLines: [String] = []
    private(set) var databaseSwitch: String?

    /// How many documents a cursor may materialise when it *is* the statement's value, which is the
    /// row cap the result grid will show plus the one document that says there are more.
    private(set) var valueCeiling: Int

    /// How many a cursor may materialise when the script reads it itself. A `forEach` over a
    /// collection is not bounded by what a grid can display, so the row cap must not reach it.
    private let iterationCeiling = PluginRowLimits.emergencyMax

    init(connection: MongoDBConnection, database: String, valueCeiling: Int) {
        self.connection = connection
        self.database = database
        self.valueCeiling = valueCeiling
    }

    /// When the script last reached the host.
    ///
    /// The runtime's watchdog reads this rather than a start time, so a script that is working
    /// through a large collection is never mistaken for one that has stopped responding.
    var lastActivity: Date {
        activityLock.lock()
        defer { activityLock.unlock() }
        return activity
    }

    func touch() {
        activityLock.lock()
        activity = Date()
        activityLock.unlock()
    }

    /// Refuses every further host call for the rest of this statement.
    ///
    /// The driver's own flag is consumed by the first `checkCancelled` that sees it, so a script
    /// that wraps its work in `try`/`catch` would swallow the cancellation and carry on querying.
    /// This latch is what makes `Cmd+.` stick: it is cleared only when the next statement starts.
    func markCancelled() {
        activityLock.lock()
        cancelled = true
        activityLock.unlock()
    }

    var isCancelled: Bool {
        activityLock.lock()
        defer { activityLock.unlock() }
        return cancelled
    }

    /// Clears what belonged to the previous statement.
    ///
    /// Cursors are pruned rather than dropped: a shell lets you keep one in a variable and read it
    /// in the next statement, so only the oldest go, and only past the ceiling.
    func beginStatement() {
        cursors.prune(keeping: Self.retainedCursors)
        printedLines.removeAll()
        databaseSwitch = nil
        activityLock.lock()
        cancelled = false
        activityLock.unlock()
        touch()
    }

    func prepare(valueCeiling: Int) {
        self.valueCeiling = valueCeiling
    }

    func reset(database: String, valueCeiling: Int) {
        cursors.removeAll()
        printedLines.removeAll()
        databaseSwitch = nil
        touch()
        self.database = database
        self.valueCeiling = valueCeiling
    }

    /// Records a printed line, or refuses once the statement has been cancelled.
    ///
    /// `print` is the one bridge that is not a `handle` call, so without this a `while (true)
    /// print("x")` would neither see the cancel latch nor ever fall silent, and the watchdog that
    /// exists for exactly that script would never fire. Printing therefore does not count as
    /// activity: only a call that reached the database does.
    func record(printed line: String) -> Bool {
        guard !isCancelled else { return false }
        guard printedLines.count < PluginRowLimits.emergencyMax else { return true }
        printedLines.append(line)
        return true
    }

    // MARK: - Dispatch

    func handle(_ requestJson: String) -> String {
        touch()
        defer { touch() }
        guard !isCancelled else {
            return MongoScriptJson.failure(message: MongoScriptText.cancelled, code: 0)
        }
        do {
            guard let data = requestJson.data(using: .utf8),
                  let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let op = request["op"] as? String else {
                throw MongoScriptError(MongoScriptText.unknownOperation(requestJson))
            }
            return MongoScriptJson.success(try perform(op: op, request: request))
        } catch is CancellationError {
            markCancelled()
            return MongoScriptJson.failure(message: MongoScriptText.cancelled, code: 0)
        } catch let error as MongoDBError {
            return MongoScriptJson.failure(message: error.message, code: error.code)
        } catch let error as MongoScriptError {
            return MongoScriptJson.failure(message: error.message, code: 0)
        } catch {
            return MongoScriptJson.failure(message: error.localizedDescription, code: 0)
        }
    }

    private func perform(op: String, request: [String: Any]) throws -> String {
        switch op {
        case "currentDatabase": return MongoScriptJson.jsonString(database)
        case "useDatabase": return try useDatabase(request)
        case "listCollections": return try listCollections(request)
        case "openCursor": return try openCursor(request)
        case "cursorConfigure": return try configureCursor(request)
        case "cursorFetch": return try fetchCursor(request)
        case "cursorCount": return try countCursor(request)
        case "cursorExplain": return try explainCursor(request)
        case "cursorClose": return closeCursor(request)
        case "command": return try runCommand(request)
        case "countDocuments": return try countDocuments(request)
        case "estimatedDocumentCount": return try estimatedCount(request)
        case "distinct": return try distinct(request)
        case "insertOne", "insertMany": return try insert(request, many: op == "insertMany")
        case "update", "replace": return try update(request, isReplace: op == "replace")
        case "delete": return try delete(request)
        case "findAndModify": return try findAndModify(request)
        case "bulkWrite": return try bulkWrite(request)
        case "createIndex": return try createIndex(request)
        case "dropIndex": return try dropIndex(request)
        case "listIndexes": return try listIndexes(request)
        case "dropCollection": return try command("{\"drop\": \(MongoScriptJson.jsonString(collectionName(request)))}", request)
        case "renameCollection": return try renameCollection(request)
        case "collectionStats":
            return try command("{\"collStats\": \(MongoScriptJson.jsonString(collectionName(request)))}", request)
        case "newObjectId": return MongoScriptJson.jsonString(MongoScriptObjectId.generate())
        case "hexToBase64": return try hexToBase64(request)
        case "encodeUuid": return try encodeUuid(request)
        case "sleep": return try sleep(request)
        default: throw MongoScriptError(MongoScriptText.unknownOperation(op))
        }
    }

    // MARK: - Cursors

    /// Drains a cursor the script left as the statement's value.
    ///
    /// Nothing has crossed into JavaScript at this point in the common case, so the documents go
    /// straight to the grid without being marshalled twice.
    func drain(handle: Int) throws -> MongoScriptDocumentBatch {
        let cursor = try cursors.cursor(for: handle)
        return try cursor.remaining { try load($0, ceiling: valueCeiling) }
    }

    func cursorDescription(handle: Int) -> (collection: String, isFind: Bool)? {
        guard let cursor = try? cursors.cursor(for: handle) else { return nil }
        return (cursor.collection, cursor.isFind)
    }

    /// The query a cursor stands for, without running it.
    ///
    /// Streaming exports need the shape of the query rather than its documents, and a cursor that
    /// nothing has read has not touched the server yet, so asking costs nothing.
    func cursorPlan(handle: Int) -> MongoScriptCursorPlan? {
        guard let cursor = try? cursors.cursor(for: handle), !cursor.isStarted else { return nil }
        return MongoScriptCursorPlan(
            database: cursor.database,
            collection: cursor.collection,
            isFind: cursor.isFind,
            filter: cursor.filterJson,
            pipeline: cursor.options.decoratedPipeline(cursor.pipelineJson),
            options: cursor.options
        )
    }

    private func openCursor(_ request: [String: Any]) throws -> String {
        let collection = collectionName(request)
        var options = MongoScriptCursorOptions.none

        let kind: MongoScriptCursor.Kind
        if (request["kind"] as? String) == "aggregate" {
            kind = .aggregate(pipeline: MongoScriptJson.rawJson(request["pipeline"]) ?? "[]")
            if let raw = MongoScriptJson.rawJson(request["options"]), raw != "null" {
                try applyAggregateOptions(raw, to: &options)
            }
        } else {
            kind = .find(filter: MongoScriptJson.rawJson(request["filter"]) ?? "{}")
            if let projection = MongoScriptJson.rawJson(request["projection"]), projection != "null" {
                options.projection = projection
            }
        }

        let cursor = cursors.open(
            kind: kind, database: databaseName(request), collection: collection, options: options
        )
        return String(cursor.handle)
    }

    private func configureCursor(_ request: [String: Any]) throws -> String {
        guard let handle = request["handle"] as? Int, let key = request["key"] as? String else {
            throw MongoScriptError(MongoScriptText.unknownCursor)
        }
        try cursors.cursor(for: handle).configure(key: key, value: MongoScriptJson.rawJson(request["value"]) ?? "null")
        return "null"
    }

    private func fetchCursor(_ request: [String: Any]) throws -> String {
        guard let handle = request["handle"] as? Int else {
            throw MongoScriptError(MongoScriptText.unknownCursor)
        }
        let page = try cursors.cursor(for: handle).page(size: Self.pageSize) {
            try load($0, ceiling: iterationCeiling)
        }
        return "{\"docs\": \(page.batch.jsonArray), \"done\": \(page.done)}"
    }

    private func countCursor(_ request: [String: Any]) throws -> String {
        guard let handle = request["handle"] as? Int else {
            throw MongoScriptError(MongoScriptText.unknownCursor)
        }
        let cursor = try cursors.cursor(for: handle)
        guard cursor.isFind else {
            let drained = try cursor.remaining { try load($0, ceiling: iterationCeiling) }
            return String(drained.json.count)
        }
        let reply = try withClient {
            try connection.scriptRunCommand(
                client: $0,
                command: """
                    {"count": \(MongoScriptJson.jsonString(cursor.collection)), "query": \(cursor.filterJson)}
                    """,
                database: cursor.database
            )
        }
        return String(MongoScriptJson.number(in: reply, key: "n") ?? 0)
    }

    private func explainCursor(_ request: [String: Any]) throws -> String {
        guard let handle = request["handle"] as? Int else {
            throw MongoScriptError(MongoScriptText.unknownCursor)
        }
        let cursor = try cursors.cursor(for: handle)
        let verbosity = (request["verbosity"] as? String) ?? "queryPlanner"
        let inner = cursor.isFind
            ? MongoScriptCommandBuilder.find(
                collection: cursor.collection, filter: cursor.filterJson,
                options: cursor.options, ceiling: valueCeiling
            )
            : MongoScriptCommandBuilder.aggregate(
                collection: cursor.collection, pipeline: cursor.pipelineJson, options: cursor.options
            )
        return try withClient {
            try connection.scriptRunCommand(
                client: $0,
                command: "{\"explain\": \(inner), \"verbosity\": \(MongoScriptJson.jsonString(verbosity))}",
                database: cursor.database
            )
        }
    }

    private func closeCursor(_ request: [String: Any]) -> String {
        if let handle = request["handle"] as? Int { cursors.close(handle: handle) }
        return "null"
    }

    /// The options document `aggregate()` takes as its second argument, which carries the same
    /// modifiers a cursor takes through chaining.
    private func applyAggregateOptions(_ raw: String, to options: inout MongoScriptCursorOptions) throws {
        for member in MongoScriptJson.members(of: raw) {
            switch member.key {
            case "hint", "collation", "batchSize", "maxTimeMS", "allowDiskUse":
                try options.apply(key: member.key, value: member.value)
            default:
                continue
            }
        }
    }

    private func load(_ cursor: MongoScriptCursor, ceiling: Int) throws -> MongoScriptDocumentBatch {
        try withClient { client in
            if cursor.isFind {
                return try connection.scriptFind(
                    client: client,
                    database: cursor.database,
                    collection: cursor.collection,
                    filter: cursor.filterJson,
                    options: cursor.options,
                    limit: ceiling
                )
            }
            return try connection.scriptAggregate(
                client: client,
                database: cursor.database,
                collection: cursor.collection,
                pipeline: cursor.pipelineJson,
                options: cursor.options,
                limit: ceiling
            )
        }
    }

    // MARK: - Commands

    private func useDatabase(_ request: [String: Any]) throws -> String {
        guard let name = request["db"] as? String, !name.isEmpty else {
            throw MongoScriptError(MongoScriptText.unknownOperation("use"))
        }
        database = name
        databaseSwitch = name
        return "null"
    }

    private func listCollections(_ request: [String: Any]) throws -> String {
        let names = try withClient {
            try connection.listCollectionsSync(client: $0, database: databaseName(request))
        }
        return "[\(names.map { MongoScriptJson.jsonString($0) }.joined(separator: ","))]"
    }

    private func runCommand(_ request: [String: Any]) throws -> String {
        try command(MongoScriptJson.rawJson(request["command"]) ?? "{}", request)
    }

    private func command(_ document: String, _ request: [String: Any]) throws -> String {
        try withClient {
            try connection.scriptRunCommand(client: $0, command: document, database: databaseName(request))
        }
    }

    private func countDocuments(_ request: [String: Any]) throws -> String {
        let count = try withClient {
            try connection.countDocumentsSync(
                client: $0,
                database: databaseName(request),
                collection: collectionName(request),
                filter: MongoScriptJson.rawJson(request["filter"]) ?? "{}",
                background: false
            )
        }
        return String(count)
    }

    private func estimatedCount(_ request: [String: Any]) throws -> String {
        let reply = try command(
            "{\"count\": \(MongoScriptJson.jsonString(collectionName(request)))}", request
        )
        return String(MongoScriptJson.number(in: reply, key: "n") ?? 0)
    }

    private func distinct(_ request: [String: Any]) throws -> String {
        let field = (request["field"] as? String) ?? ""
        let reply = try command(
            """
            {"distinct": \(MongoScriptJson.jsonString(collectionName(request))), \
            "key": \(MongoScriptJson.jsonString(field)), \
            "query": \(MongoScriptJson.rawJson(request["filter"]) ?? "{}")}
            """,
            request
        )
        return MongoScriptJson.member(of: reply, key: "values") ?? "[]"
    }

    private func insert(_ request: [String: Any], many: Bool) throws -> String {
        let documents: [String]
        if many {
            documents = MongoScriptJson.topLevelElements(MongoScriptJson.rawJson(request["documents"]) ?? "[]")
        } else {
            documents = [MongoScriptJson.rawJson(request["document"]) ?? "{}"]
        }
        let inserted = try withClient {
            try connection.scriptInsert(
                client: $0,
                database: databaseName(request),
                collection: collectionName(request),
                documents: documents
            )
        }
        let ids = inserted.map { $0 }.joined(separator: ",")
        return "{\"insertedIds\": [\(ids)], \"insertedCount\": \(inserted.count)}"
    }

    private func update(_ request: [String: Any], isReplace: Bool) throws -> String {
        let options = MongoScriptJson.options(request["options"])
        let statement = MongoScriptCommandBuilder.update(
            collection: collectionName(request),
            filter: MongoScriptJson.rawJson(request["filter"]) ?? "{}",
            update: MongoScriptJson.rawJson(request["update"]) ?? "{}",
            multi: !isReplace && (request["multi"] as? Bool ?? false),
            options: options
        )
        return try command(statement, request)
    }

    private func delete(_ request: [String: Any]) throws -> String {
        let statement = MongoScriptCommandBuilder.delete(
            collection: collectionName(request),
            filter: MongoScriptJson.rawJson(request["filter"]) ?? "{}",
            multi: request["multi"] as? Bool ?? false,
            options: MongoScriptJson.options(request["options"])
        )
        return try command(statement, request)
    }

    private func findAndModify(_ request: [String: Any]) throws -> String {
        let statement = MongoScriptCommandBuilder.findAndModify(
            collection: collectionName(request),
            filter: MongoScriptJson.rawJson(request["filter"]) ?? "{}",
            update: MongoScriptJson.rawJson(request["update"]),
            remove: request["remove"] as? Bool ?? false,
            options: MongoScriptJson.options(request["options"])
        )
        return try command(statement, request)
    }

    private func bulkWrite(_ request: [String: Any]) throws -> String {
        let operations = MongoScriptJson.topLevelElements(MongoScriptJson.rawJson(request["operations"]) ?? "[]")
        var inserted = 0
        var matched = 0
        var modified = 0
        var deleted = 0
        var upserted = 0

        for operation in operations {
            let statement = try MongoScriptCommandBuilder.bulkOperation(
                operation, collection: collectionName(request)
            )
            let reply = try command(statement.document, request)
            switch statement.kind {
            case .insert: inserted += Int(MongoScriptJson.number(in: reply, key: "n") ?? 0)
            case .update:
                matched += Int(MongoScriptJson.number(in: reply, key: "n") ?? 0)
                modified += Int(MongoScriptJson.number(in: reply, key: "nModified") ?? 0)
                upserted += MongoScriptJson.member(of: reply, key: "upserted") == nil ? 0 : 1
            case .delete: deleted += Int(MongoScriptJson.number(in: reply, key: "n") ?? 0)
            }
        }

        return """
            {"insertedCount": \(inserted), "matchedCount": \(matched), "modifiedCount": \(modified), \
            "deletedCount": \(deleted), "upsertedCount": \(upserted)}
            """
    }

    private func createIndex(_ request: [String: Any]) throws -> String {
        let statement = MongoScriptCommandBuilder.createIndex(
            collection: collectionName(request),
            keys: MongoScriptJson.rawJson(request["keys"]) ?? "{}",
            options: MongoScriptJson.options(request["options"])
        )
        return try command(statement, request)
    }

    private func dropIndex(_ request: [String: Any]) throws -> String {
        try command(
            """
            {"dropIndexes": \(MongoScriptJson.jsonString(collectionName(request))), \
            "index": \(MongoScriptJson.rawJson(request["index"]) ?? "\"*\"")}
            """,
            request
        )
    }

    private func listIndexes(_ request: [String: Any]) throws -> String {
        let indexes = try withClient {
            try connection.listIndexesJsonSync(
                client: $0, database: databaseName(request), collection: collectionName(request)
            )
        }
        return "[\(indexes.joined(separator: ","))]"
    }

    private func renameCollection(_ request: [String: Any]) throws -> String {
        let source = "\(databaseName(request)).\(collectionName(request))"
        let target = "\(databaseName(request)).\((request["target"] as? String) ?? "")"
        return try withClient {
            try connection.scriptRunCommand(
                client: $0,
                command: """
                    {"renameCollection": \(MongoScriptJson.jsonString(source)), "to": \(MongoScriptJson.jsonString(target)), \
                    "dropTarget": \(request["dropTarget"] as? Bool ?? false)}
                    """,
                database: "admin"
            )
        }
    }

    // MARK: - Value Helpers

    private func hexToBase64(_ request: [String: Any]) throws -> String {
        guard let hex = request["hex"] as? String, let data = MongoScriptObjectId.data(fromHex: hex) else {
            throw MongoScriptError(MongoScriptText.invalidDocument("HexData"))
        }
        return MongoScriptJson.jsonString(data.base64EncodedString())
    }

    /// The constructor's own tag decides the subtype and the byte order, so it reaches the codec
    /// rather than being normalised to `UUID`.
    private func encodeUuid(_ request: [String: Any]) throws -> String {
        let text = (request["value"] as? String) ?? UUID().uuidString
        let tag = (request["tag"] as? String) ?? "UUID"
        guard let binary = MongoDBUuidCodec.parseWrapper("\(tag)(\"\(text)\")") else {
            throw MongoScriptError(MongoScriptText.invalidDocument("\(tag)(\(text))"))
        }
        return """
            {"base64": \(MongoScriptJson.jsonString(binary.data.base64EncodedString())), \
            "subtype": \(binary.subtype), "text": \(MongoScriptJson.jsonString(text.lowercased()))}
            """
    }

    private func sleep(_ request: [String: Any]) throws -> String {
        let milliseconds = (request["ms"] as? NSNumber)?.doubleValue ?? 0
        guard milliseconds.isFinite, milliseconds > 0 else { return "null" }
        let deadline = Date().addingTimeInterval(min(milliseconds, 60_000) / 1_000)
        while Date() < deadline {
            try connection.checkCancelled()
            touch()
            Thread.sleep(forTimeInterval: 0.02)
        }
        return "null"
    }

    // MARK: - Plumbing

    private func withClient<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        #if canImport(CLibMongoc)
        return try connection.withClientSync(body)
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    private func databaseName(_ request: [String: Any]) -> String {
        let named = (request["db"] as? String) ?? ""
        return named.isEmpty ? database : named
    }

    private func collectionName(_ request: [String: Any]) -> String {
        (request["collection"] as? String) ?? ""
    }
}

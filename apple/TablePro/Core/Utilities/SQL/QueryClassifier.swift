//
//  QueryClassifier.swift
//  TablePro
//

import Foundation
import TableProFirebaseCore
import TableProPluginKit
import TableProQdrantCore
import TableProRedisCore
import TableProSQLGrammar
import TableProWeaviateCore

typealias QueryTier = StatementTier
typealias QueryClassification = StatementClassification

/// The app's tiering of what a connection's text runs. SQL goes to ``SQLStatementClassifier``, which the iOS app
/// shares; the engines whose drivers take requests or commands of their own are read here, the way each driver reads
/// them.
enum QueryClassifier {
    static func classify(_ sql: String, databaseType: DatabaseType) -> QueryClassification {
        classify(sql, databaseType: databaseType, readings: databaseType.lexicalReadings)
    }

    static func classify(
        _ sql: String,
        databaseType: DatabaseType,
        readings: SQLLexicalReadings
    ) -> QueryClassification {
        classify(sql, databaseType: databaseType, readings: readings) { $0 == .mostSevere }
    }

    private static func classify(
        _ sql: String,
        databaseType: DatabaseType,
        readings: SQLLexicalReadings,
        until isSettled: (QueryClassification) -> Bool
    ) -> QueryClassification {
        if let document = documentStoreClassification(sql, databaseType: databaseType, readings: readings) {
            return document
        }
        if let redis = redisClassification(sql, databaseType: databaseType) { return redis }
        let leading = StatementBlank.trimming(SQLLeadingComments.stripping(sql, grammar: readings.execution))
        if let ledger = beancountClassification(leading, databaseType: databaseType) { return ledger }
        return SQLStatementClassifier.classify(
            sql,
            databaseTypeId: databaseType.rawValue,
            readings: readings,
            request: requestClassification(for: databaseType),
            until: isSettled
        )
    }

    private static func requestClassification(for databaseType: DatabaseType) -> SQLStatementClassifier.RequestClassification? {
        switch databaseType {
        case .dynamodb:
            return { statement, grammar in dynamoDBClassification(statement, grammar: grammar) }
        case .influxdb:
            return { statement, _ in fluxClassification(statement) }
        default:
            return nil
        }
    }

    // Nil on an engine with a query language of its own, Cypher, KafkaQL or a shell: which of its commands define,
    // grant or set the session is not a SQL question.
    static func isSQLDataStatement(_ sql: String, databaseType: DatabaseType) -> Bool? {
        let readings = databaseType.lexicalReadings
        guard (PluginMetadataRegistry.shared.snapshot(for: databaseType)?.editorLanguage ?? .sql) == .sql,
              documentStoreClassification(sql, databaseType: databaseType, readings: readings) == nil,
              redisClassification(sql, databaseType: databaseType) == nil
        else { return nil }
        let leading = StatementBlank.trimming(SQLLeadingComments.stripping(sql, grammar: readings.execution))
        guard beancountClassification(leading, databaseType: databaseType) == nil else { return nil }
        return SQLStatementClassifier.isDataStatement(
            sql,
            databaseTypeId: databaseType.rawValue,
            readings: readings,
            request: requestClassification(for: databaseType),
            requestIsData: requestDataStatement(for: databaseType)
        )
    }

    private static func requestDataStatement(for databaseType: DatabaseType) -> SQLStatementClassifier.RequestDataStatement? {
        switch databaseType {
        case .dynamodb:
            return { statement, grammar in dynamoDBIsDataStatement(statement, grammar: grammar) }
        case .influxdb:
            return { statement, _ in fluxIsDataStatement(statement) }
        default:
            return nil
        }
    }

    static func isWriteQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        let readings = databaseType.lexicalReadings
        return classify(sql, databaseType: databaseType, readings: readings) { $0.tier != .safe }.tier != .safe
    }

    static func isDangerousQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        isDangerousQuery(sql, databaseType: databaseType, readings: databaseType.lexicalReadings)
    }

    static func isDangerousQuery(_ sql: String, databaseType: DatabaseType, readings: SQLLexicalReadings) -> Bool {
        let classification = classify(sql, databaseType: databaseType, readings: readings) { $0.tier == .destructive }
        if classification.tier == .destructive { return true }
        // A MongoDB statement is JavaScript, where `delete d.x` removes a field from a local object.
        guard databaseType != .redis, databaseType != .mongodb else { return false }
        if databaseType == .neo4j { return cypherDeletesUnfiltered(sql) }
        // A request engine's own reading already tiers each delete of more than one item as destructive.
        guard documentStoreClassification(sql, databaseType: databaseType, readings: readings) == nil else {
            return false
        }
        let request: SQLStatementClassifier.RequestDeletion? = databaseType == .dynamodb
            ? { statement, grammar in dynamoDBDeletesEveryRow(statement, grammar: grammar) }
            : nil
        return SQLStatementClassifier.deletesEveryRow(
            sql, databaseTypeId: databaseType.rawValue, readings: readings, request: request
        )
    }

    static func classifyTier(_ sql: String, databaseType: DatabaseType) -> QueryTier {
        let readings = databaseType.lexicalReadings
        return classify(sql, databaseType: databaseType, readings: readings) { $0.tier == .destructive }.tier
    }

    static func reachesFilesystemOrExecutesCode(_ sql: String, databaseType: DatabaseType) -> Bool {
        classify(sql, databaseType: databaseType).reachesFilesystemOrExecutesCode
    }

    static func isMultiStatement(_ sql: String, databaseType: DatabaseType) -> Bool {
        isMultiStatement(sql, databaseType: databaseType, readings: databaseType.lexicalReadings)
    }

    /// Whether `sql` runs more than one statement: it holds several, a `GO n` line runs its one statement n times, it
    /// ends inside a block it opened, which an engine that reads the opener as a name runs as several statements, or a
    /// T-SQL block in it holds several. A caller that sends one statement once cannot honour the count, and dropping it
    /// runs the statement once.
    static func isMultiStatement(_ sql: String, databaseType: DatabaseType, readings: SQLLexicalReadings) -> Bool {
        let model = QueryStatementModel.forDatabaseType(databaseType)
        guard let lexings = readings.lexings(of: sql) else { return true }
        return lexings.contains { lexing in
            let batches = QueryBatchPlanner.batches(in: lexing.text, model: model, grammar: lexing.grammar)
            let statements = batches.flatMap(\.statements)
            return statements.count > 1 || batches.contains { $0.repeatCount > 1 }
                || SQLStatementScanner.endsInsideOpenBlock(lexing.text, grammar: lexing.grammar)
                || statements.contains { statement in
                    SQLUnterminatedStatements.blockHoldsSeveralStatements(statement.sql, grammar: lexing.grammar)
                }
        }
    }

    /// The statements `grammar` splits `sql` into, as the driver would receive them.
    static func statements(of sql: String, grammar: SQLLexicalGrammar) -> [String] {
        SQLStatementClassifier.statements(of: sql, grammar: grammar)
    }

    static func isExplainStatement(_ sql: String, grammar: SQLLexicalGrammar) -> Bool {
        let upper = SQLLeadingComments.stripping(sql, grammar: grammar).uppercased()
        return explainPrefixes.contains { prefix in
            guard upper.hasPrefix(prefix), let boundary = upper.dropFirst(prefix.count).first else {
                return false
            }
            return boundary == "(" || boundary.isWhitespace
        }
    }

    static func explainedStatement(in sql: String, databaseType: DatabaseType) -> String? {
        let text = StatementBlank.trimming(sql)
        guard let explain = SQLExplainStatement.read(text, grammar: databaseType.lexicalGrammar),
              explainPrefixes.contains(explain.keyword),
              case .explains(let start, _) = explain.reading
        else { return nil }
        return StatementBlank.trimming((text as NSString).substring(from: start))
    }

    /// A parenthesised query expression is idiomatic when each arm of a set operation carries its
    /// own ORDER BY, so the opening parens are skipped to reach the keyword that classifies the
    /// statement. Skipping cannot loosen the classification: an unrecognised keyword still falls to
    /// the write arm, and the body-wide filesystem and destructive scans run over the whole text.
    static func leadingKeyword(of sql: String, grammar: SQLLexicalGrammar) -> String {
        var remaining = SQLLeadingComments.stripping(sql, grammar: grammar)[...]
        while remaining.first == "(" {
            remaining = SQLLeadingComments.stripping(String(remaining.dropFirst()), grammar: grammar)[...]
        }
        return remaining.prefix { $0.isLetter || $0.isNumber || $0 == "_" }.uppercased()
    }

    private static let explainPrefixes: [String] = ["EXPLAIN", "ANALYZE"]
}

extension QueryClassifier {
    static let redisDestructiveCommands: Set<String> = [
        "FLUSHDB", "FLUSHALL", "SHUTDOWN", "MIGRATE", "SWAPDB", "REPLICAOF", "SLAVEOF",
        "CLUSTER", "FAILOVER", "RESET"
    ]

    static let redisCodeExecutionCommands: Set<String> = [
        "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO",
        "FUNCTION", "SCRIPT", "MODULE", "DEBUG"
    ]

    static let redisFilesystemCommands: Set<String> = [
        "SAVE", "BGSAVE", "BGREWRITEAOF", "DEBUG"
    ]

    // Redis has no comments, so every command the driver will run is tiered, and the worst one wins.
    static func redisClassification(
        _ text: String,
        databaseType: DatabaseType
    ) -> QueryClassification? {
        guard databaseType == .redis else { return nil }
        return RedisCommandSplitter.commands(in: text).reduce(QueryClassification.safe) { worst, command in
            worst.escalated(with: redisCommandClassification(StatementBlank.trimming(command.text)))
        }
    }

    static func redisCommandClassification(_ command: String) -> QueryClassification {
        guard let arguments = RedisArgumentCodec.split(command) else {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        }
        let statement = redisCommandPastPrefixes(arguments.map { String(bytes: $0, encoding: .utf8) ?? "" })
        guard let command = statement.first?.uppercased() else { return .safe }

        let touchesUnsafeSurface = redisCodeExecutionCommands.contains(command)
            || redisFilesystemCommands.contains(command)

        if command == "CONFIG" {
            let tier: QueryTier = RedisReadCommands.onlyReads(statement) ? .safe : .destructive
            return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: false)
        }

        if redisDestructiveCommands.contains(command) || command == "DEBUG" {
            return QueryClassification(
                tier: .destructive,
                reachesFilesystemOrExecutesCode: touchesUnsafeSurface
            )
        }

        if RedisReadCommands.onlyReads(statement) {
            return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: false)
        }

        return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
    }

    /// `DB <index> <command>`, `OUTSIDEBLOCK <command>` and `MUSTAPPLY <command>` run the command they wrap, so that
    /// command decides the tier: read as the bare prefix, `DB 0 FLUSHDB` would pass as an ordinary
    /// write. A prefix with nothing after it is left whole, which classifies as a write. The words are
    /// read the way the driver reads them, so a quoted `"FLUSHALL"` is the command it runs.
    static func redisCommandPastPrefixes(_ words: [String]) -> ArraySlice<String> {
        var rest = words[...]
        while let first = rest.first?.uppercased() {
            if first == "DB", rest.count > 2 {
                rest = rest.dropFirst(2)
            } else if first == "OUTSIDEBLOCK" || first == "MUSTAPPLY", rest.count > 1 {
                rest = rest.dropFirst()
            } else {
                break
            }
        }
        return rest
    }

    /// Beancount answers BQL, whose statements (`SELECT`, `BALANCES`, `JOURNAL`, `PRINT`) only
    /// read, and the two `PRAGMA` forms its driver accepts. Anything else falls through to SQL.
    static func beancountClassification(
        _ trimmed: String,
        databaseType: DatabaseType
    ) -> QueryClassification? {
        guard databaseType == .beancount else { return nil }
        let lowered = trimmed.lowercased()
        guard beancountReadPrefixes.contains(where: lowered.hasPrefix) else { return nil }
        return .safe
    }

    private static let beancountReadPrefixes = ["bql:", "bql ", "pragma table_info", "pragma database_list"]

    // A request driver gets the statements the scanner cuts, so each is tiered as cut and the worst one wins.
    static func documentStoreClassification(
        _ sql: String,
        databaseType: DatabaseType,
        readings: SQLLexicalReadings
    ) -> QueryClassification? {
        func worstRequest(_ classification: (String) -> QueryClassification) -> QueryClassification {
            readings.all.flatMap { statements(of: sql, grammar: $0) }.reduce(.safe) { worst, request in
                worst.escalated(with: classification(request))
            }
        }
        switch databaseType {
        case .mongodb:
            return mongoClassification(sql)
        case .elasticsearch:
            return worstRequest(elasticsearchClassification)
        case .etcd:
            return worstRequest(etcdClassification)
        case .typesense:
            return worstRequest(typesenseClassification)
        case .weaviate:
            return worstRequest(weaviateClassification)
        case .qdrant:
            return worstRequest(qdrantClassification)
        case .memcached:
            return worstRequest(memcachedClassification)
        case .firestore, .firebaseRealtimeDatabase:
            return worstRequest { firebaseClassification($0, databaseType: databaseType) }
        case .bigtable:
            return worstRequest(bigtableClassification)
        case .neo4j:
            return cypherClassification(sql)
        default:
            return nil
        }
    }

    // The APIs a POST may reach and still only read (REST API spec 8.19). `POST /orders/_mapping` changes the mapping.
    static let elasticsearchReadEndpoints: Set<String> = [
        "_search", "_count", "_msearch", "_explain", "_analyze", "_field_caps", "_validate", "_render", "_sql",
        "_mget", "_query", "_knn_search", "_termvectors", "_mtermvectors", "_terms_enum", "_search_shards",
        "_rank_eval", "_mvt"
    ]

    // Read the way `ElasticsearchConsoleParser` reads a console request: the method and path on the first line, the
    // rest a body. The driver sends a GET or HEAD that carries a body as a POST, so `GET /orders/_delete_by_query` with
    // a query under it deletes, and it is classified as that POST.
    static func elasticsearchClassification(_ sql: String) -> QueryClassification {
        let request = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = request.components(separatedBy: "\n")
        let header = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        let hasBody = !lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let declared = parts.first.map { $0.uppercased() } ?? ""
        let method = hasBody && (declared == "GET" || declared == "HEAD") ? "POST" : declared
        let path = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let upper = request.uppercased()
        let touchesUnsafeSurface = upper.contains("_SCRIPTS") || upper.contains("_PAINLESS_EXECUTE")

        let tier: QueryTier
        switch method {
        case "GET", "HEAD":
            tier = .safe
        case "POST":
            if path.lowercased().contains("_delete_by_query") {
                tier = .destructive
            } else {
                let readsOnly = elasticsearchEndpoint(of: path).map(elasticsearchReadEndpoints.contains) ?? false
                tier = readsOnly && !elasticsearchKeepsResults(path) ? .safe : .write
            }
        case "DELETE":
            tier = elasticsearchDeletesOneDocument(path) ? .write : .destructive
        default:
            tier = .write
        }
        return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
    }

    // `/<index>/_doc/<id>` on one concrete index. A name cannot start with `_`, `-` or `+`, one starting with `.` is a
    // system index, and the characters below make a pattern, a list, date math or a remote target. An id starting with
    // `_` stays destructive, as older servers read `/<index>/<type>/_query` as a delete by query.
    static func elasticsearchDeletesOneDocument(_ path: String) -> Bool {
        let rooted = path.hasPrefix("/") ? path : "/" + path
        guard elasticsearchEndpoint(of: rooted) == "_doc" else { return false }
        let route = rooted.prefix { $0 != "?" && $0 != "#" }
        let segments = Array(route.split(separator: "/", omittingEmptySubsequences: false).dropFirst())
        guard segments.count == 3, segments[1] == "_doc", let idStart = segments[2].first, idStart != "_",
              let indexStart = segments[0].first, !"_-+.".contains(indexStart)
        else { return false }
        return !segments[0].contains { elasticsearchIndexExpressionCharacters.contains($0) }
    }

    private static let elasticsearchIndexExpressionCharacters: Set<Character> = [
        "*", "?", ",", "<", ">", ":", "|", "\""
    ]

    /// The first path segment naming an API, `_search` in `/orders/_search/template`, since an index
    /// name cannot start with `_` and the body or an index may spell `_search` anywhere. Nil when the
    /// URL the driver builds could reach another path: a `.` or `..` segment resolves away, and a
    /// space, `%` or `\` is encoded or decoded on the way.
    static func elasticsearchEndpoint(of path: String) -> String? {
        let route = path.prefix { $0 != "?" && $0 != "#" }
        guard !route.contains(where: { $0.isWhitespace || $0 == "%" || $0 == "\\" }) else { return nil }
        let segments = route.split(separator: "/")
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        // `_all` is a target, not an API: `GET /_all/_search`.
        return segments.first { $0.hasPrefix("_") && $0 != "_all" }.map(String.init)
    }

    // An async ES|QL query keeps its results on the cluster, as `_async_search` does.
    static func elasticsearchKeepsResults(_ path: String) -> Bool {
        let segments = path.prefix { $0 != "?" && $0 != "#" }.split(separator: "/")
        return zip(segments, segments.dropFirst()).contains { $0 == "_query" && $1 == "async" }
    }

    // A snapshot writes to a server path and `/keys` mints API keys.
    static let typesenseUnsafePaths: [[String]] = [["OPERATIONS", "SNAPSHOT"], ["KEYS"]]

    /// The verb and the path, and nothing else. A Typesense console request is one header line
    /// followed by a JSON body, and the body is the caller's data: scanning the whole statement
    /// let `POST /collections/c/documents/import` carrying `"note": "/multi_search"` in a field
    /// read as a search, which is a read-only mode and MCP gate bypass. A URL path holds no raw
    /// whitespace, so the path ends at the first one: that keeps a body written on the header line
    /// out of it, and stops `POST /collections/c /multi_search` from ending in a read path.
    static func typesenseRequestLine(_ trimmed: String) -> (verb: String, path: String) {
        let header = trimmed.firstIndex(where: \.isNewline).map { String(trimmed[..<$0]) } ?? trimmed
        let parts = header.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard let verb = parts.first else { return ("", "/") }
        guard parts.count == 2 else { return (String(verb).uppercased(), "/") }

        var path = String(parts[1].trimmingCharacters(in: .whitespaces).prefix { character in
            character != "?" && character != "#" && !character.isWhitespace
        })
        if !path.hasPrefix("/") { path = "/" + path }
        return (String(verb).uppercased(), path.uppercased())
    }

    // Resolved with `URL(string:relativeTo:)` as the driver resolves it, so `/a/../keys` and `//host/keys` are `/keys`.
    // A dot segment an escape hid could still move the request.
    static func typesenseRoute(of path: String) -> [String]? {
        guard let base = typesenseResolutionBase,
              let resolved = URL(string: path, relativeTo: base)?.absoluteURL,
              let decoded = resolved.path(percentEncoded: true).removingPercentEncoding
        else { return nil }
        let segments = decoded.split(separator: "/").map { $0.uppercased() }
        guard !segments.contains(where: { $0 == "." || $0 == ".." || $0.contains("%") }) else { return nil }
        return segments
    }

    static let typesenseResolutionBase = URL(string: "http://typesense.invalid/")

    static func typesenseReadsOnly(_ route: [String]) -> Bool {
        if route == ["MULTI_SEARCH"] { return true }
        guard route.count == 4, route[0] == "COLLECTIONS", route[2] == "DOCUMENTS" else { return false }
        return route[3] == "SEARCH" || route[3] == "EXPORT"
    }

    static func typesenseClassification(_ trimmed: String) -> QueryClassification {
        let (verb, path) = typesenseRequestLine(trimmed)
        let route = typesenseRoute(of: path)
        let touchesUnsafeSurface = route.map { route in
            typesenseUnsafePaths.contains { unsafe in route.starts(with: unsafe) }
        } ?? true
        if verb == "GET" || verb == "HEAD" {
            return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        if verb == "POST", route.map(typesenseReadsOnly) == true {
            return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        if verb == "DELETE" {
            let tier: QueryTier = route.map(typesenseNamesOneDocument) == true ? .write : .destructive
            return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
    }

    // `/collections/<c>/documents/<id>`. Without the id, a DELETE removes every document its `filter_by` matches.
    static func typesenseNamesOneDocument(_ route: [String]) -> Bool {
        route.count == 4 && route[0] == "COLLECTIONS" && route[2] == "DOCUMENTS"
            && !["IMPORT", "EXPORT", "SEARCH"].contains(route[3])
    }

    /// A bare operation, a `{"query": ...}` envelope and a console body are the same request, and
    /// the driver forwards the envelope verbatim, so the read-only gate has to read all three.
    static func weaviateDeclaresMutation(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("mutation") {
            return true
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = object["query"] as? String
        else { return false }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("mutation")
    }

    // Read in the order the driver reads it, with the driver's own console parser, so the request tiered is the one the
    // driver sends: `DELETE` and its path may be split by any whitespace.
    static func weaviateClassification(_ statement: String) -> QueryClassification {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "select 1" || WeaviateBrowseQuery.isTagged(trimmed) {
            return .safe
        }
        if WeaviateWriteCodec.isTagged(trimmed) {
            guard let tagged = WeaviateWriteCodec.decode(trimmed), tagged.method.uppercased() == "DELETE" else {
                return .write
            }
            return weaviateDeletesOneObject(path: tagged.path) ? .write : .destructive
        }
        if let request = WeaviateConsoleParser.parse(trimmed) {
            return weaviateClassification(of: request)
        }
        if WeaviateGraphQL.looksLikeGraphQL(trimmed) {
            return weaviateDeclaresMutation(trimmed) ? .write : .safe
        }
        // The driver refuses any other text, and an unknown request is a write all the same.
        return .write
    }

    static func weaviateClassification(of request: WeaviateConsoleRequest) -> QueryClassification {
        switch request.method {
        case "GET", "HEAD":
            return .safe
        case "DELETE":
            return weaviateDeletesOneObject(path: request.path) ? .write : .destructive
        case "POST" where request.path.hasPrefix("/v1/graphql"):
            guard let body = request.body else { return .write }
            return weaviateDeclaresMutation(body) ? .write : .safe
        default:
            return .write
        }
    }

    // `/v1/objects/<className>/<id>`, or one reference on one object,
    // `/v1/objects/[<className>/]<id>/references/<name>`. `/v1/objects/<id>` without a class deletes that UUID in every
    // class that holds one (Weaviate's `deleteObjectFromRepo`), so it stays destructive.
    static func weaviateDeletesOneObject(path: String) -> Bool {
        guard let segments = weaviateSegments(of: path), segments.count >= 4,
              segments[0] == "v1", segments[1] == "objects"
        else { return false }
        switch segments.count {
        case 4: return true
        case 5: return segments[3] == "references"
        case 6: return segments[4] == "references"
        default: return false
        }
    }

    // The driver runs what `QdrantConsoleParser` parses, so the gate reads the same request.
    static func qdrantClassification(_ trimmed: String) -> QueryClassification {
        if QdrantOperations.isTagged(trimmed) {
            return .safe
        }
        guard let request = QdrantConsoleParser.parse(trimmed) else { return .safe }
        let kind = request.kind
        let tier: QueryTier = switch kind.tier {
        case .read: .safe
        case .write: .write
        case .remove: qdrantDeletesOnePoint(request) ? .write : .destructive
        }
        return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: kind.touchesServerFiles)
    }

    // Qdrant's `PointsSelector` is a list of ids or a filter, either with an optional `shard_key`. Any other key, a
    // filter or a second id can remove more than one point.
    static func qdrantDeletesOnePoint(_ request: QdrantConsoleRequest) -> Bool {
        guard request.method == "POST",
              let route = QdrantPathEncoding.segments(of: request.path), route.count == 4,
              route[0] == "collections", route[2] == "points", route[3] == "delete",
              let data = request.body?.data(using: .utf8),
              let selector = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(selector.keys).isSubset(of: ["points", "shard_key"]),
              let points = selector["points"] as? [Any], points.count == 1
        else { return false }
        switch points[0] {
        case let number as NSNumber:
            return CFGetTypeID(number) != CFBooleanGetTypeID()
        case is String:
            return true
        default:
            return false
        }
    }

    // A grid page is a tagged spec, which only reads. Anything else is read with the driver's own parser, so the path
    // tiered is the path the driver writes. A write that leaves a node holding nothing deletes it, so it ranks with
    // DELETE: a write when it removes one document or one record, destructive otherwise.
    static func firebaseClassification(_ statement: String, databaseType: DatabaseType) -> QueryClassification {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.unicodeScalars.starts(with: FirebaseStatement.browseTag.unicodeScalars) {
            return .safe
        }
        // The driver refuses any other text, and an unknown request is a write all the same.
        guard case .request(let request)? = try? FirebaseStatement.parse(trimmed) else { return .write }
        let body = request.body ?? ""
        let path = request.path.unicodeScalars.split(separator: "/").map(String.init)
        let realtimeDatabase = databaseType == .firebaseRealtimeDatabase
        switch request.method {
        case .get, .query:
            return .safe
        case .delete where databaseType == .firestore:
            return firestoreNamesDocument(path) ? .write : .destructive
        case .delete:
            return realtimeDatabase && realtimeDatabaseRemovesOnlyRecords([path]) ? .write : .destructive
        case .put where request.path.isEmpty:
            return .destructive
        // A PUT replaces the node at its path, every record under a table's node with it.
        case .put where realtimeDatabase:
            if firebaseHoldsNothing(body) { return realtimeDatabaseRemovesOnlyRecords([path]) ? .write : .destructive }
            return path.count >= 2 ? .write : .destructive
        case .put where firebaseHoldsNothing(body):
            return .destructive
        case .patch where realtimeDatabase:
            return realtimeDatabasePatchChangesOnlyRecords(path, body: body) ? .write : .destructive
        case .put, .patch, .post:
            return .write
        }
    }

    // An even number of segments names one document. Firestore refuses `.` and `..` as IDs, and the driver sends them as
    // written, where the front end may resolve them to another path.
    static func firestoreNamesDocument(_ path: [String]) -> Bool {
        !path.isEmpty && path.count.isMultiple(of: 2) && !path.contains { $0 == "." || $0 == ".." }
    }

    // The plugin lists `/` and each top-level key as tables (`FirebasePluginDriver.fetchTables`), so only a node two
    // levels down is one record. A key cannot hold `.`, so a path through one names the server's own node.
    static func realtimeDatabaseRemovesOnlyRecords(_ nodes: [[String]]) -> Bool {
        nodes.allSatisfy { node in node.count >= 2 && !node.contains { $0.unicodeScalars.contains(".") } }
    }

    // Each key of a PATCH body is a path below the request's, and the PATCH replaces each child it names: one set to
    // nothing is removed, any other replaces every record under it. A metadata key sets its own node.
    static func realtimeDatabasePatchChangesOnlyRecords(_ path: [String], body: String) -> Bool {
        guard let members = firebaseJSON(body) as? [String: Any] else { return true }
        return members.allSatisfy { key, value in
            var node = path + key.unicodeScalars.split(separator: "/").map(String.init)
            if firebaseHoldsNothing(json: value) { return realtimeDatabaseRemovesOnlyRecords([node]) }
            if let last = node.last, realtimeDatabaseMetadataKeys.contains(last) { node.removeLast() }
            return node.count >= 2
        }
    }

    static func firebaseHoldsNothing(_ body: String) -> Bool {
        guard let json = firebaseJSON(body) else { return false }
        return firebaseHoldsNothing(json: json)
    }

    private static func firebaseJSON(_ body: String) -> Any? {
        guard let data = body.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // Read as the Realtime Database stores JSON: a non-null `.value` is the node's value, `.sv` is one the server fills
    // in, and any other key starting with `.` is metadata, so `{".priority": 1}` stores nothing.
    private static func firebaseHoldsNothing(json: Any) -> Bool {
        switch json {
        case is NSNull:
            return true
        case let members as [String: Any]:
            if let value = members[".value"], !(value is NSNull) {
                return firebaseHoldsNothing(json: value)
            }
            if members[".sv"] != nil {
                return false
            }
            return members.allSatisfy { key, value in
                key.unicodeScalars.first == "." || firebaseHoldsNothing(json: value)
            }
        case let items as [Any]:
            return items.allSatisfy { firebaseHoldsNothing(json: $0) }
        default:
            return false
        }
    }

    // Every change names one row by its key (`BigtableRequest.parse`) and runs as one `mutateRow`, so a DELETE or a PUT
    // that nulls a cell removes from that row only.
    static func bigtableClassification(_ trimmed: String) -> QueryClassification {
        if trimmed.hasPrefix("BIGTABLE_BROWSE:") {
            return .safe
        }
        switch trimmed.prefix(while: { !$0.isWhitespace }).uppercased() {
        case "GET", "SCAN", "READ":
            return .safe
        default:
            return .write
        }
    }
}

//
//  QueryClassifier+RequestDataStatements.swift
//  TablePro
//

import Foundation
import TableProFirebaseCore
import TableProQdrantCore
import TableProSQLGrammar
import TableProWeaviateCore

// A request engine's change is named by its method and the route template of the engine's API reference, such as
// `PUT /{target}/_doc/{id}`. Each driver reads the whole text as one request, so each reader here does too.
extension QueryClassifier {
    static func elasticsearchDataCommands(_ text: String) -> [DataCommand]? {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = request.components(separatedBy: "\n")
        let header = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let declared = parts.first.map({ $0.uppercased() }), elasticsearchMethods.contains(declared) else {
            return nil
        }
        var path = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : "/"
        if !path.hasPrefix("/") { path = "/" + path }
        // From here on the URL parser reads the path, scalar by scalar.
        let route = String(path.unicodeScalars.prefix(while: { $0 != "?" && $0 != "#" }))
        if elasticsearchClassification(request).tier == .safe, !elasticsearchRunsServerCommand(route) {
            return [.read]
        }
        guard let segments = elasticsearchSegments(of: route) else { return nil }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // The driver sends a GET or HEAD that carries a body as a POST.
        let method = !body.isEmpty && (declared == "GET" || declared == "HEAD") ? "POST" : declared
        let api = segments.firstIndex { $0.unicodeScalars.first == "_" && $0 != "_all" } ?? segments.count
        let rest = path.unicodeScalars.dropFirst(route.unicodeScalars.count)
        let query = rest.first == "?" ? String(rest.dropFirst().prefix(while: { $0 != "#" })) : ""
        if segments[..<api].contains(where: elasticsearchNamesSystemIndex) || elasticsearchExpandsToHidden(query) {
            return [.refused]
        }
        if segments[api...].first == "_bulk" {
            guard let indices = elasticsearchBulkIndices(body) else { return nil }
            if indices.contains(where: elasticsearchNamesSystemIndex) { return [.refused] }
        }
        return [.named(method + " /" + elasticsearchTemplate(segments, api: api).joined(separator: "/"))]
    }

    static func typesenseDataCommands(_ text: String) -> [DataCommand]? {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = request.components(separatedBy: "\n")[0].trimmingCharacters(in: .whitespaces)
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let method = parts.first.map({ $0.uppercased() }), typesenseMethods.contains(method) else { return nil }
        var path = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : "/"
        if !path.hasPrefix("/") { path = "/" + path }
        // The driver refuses a path with whitespace before its query string.
        guard !path.prefix(while: { $0 != "?" }).contains(where: \.isWhitespace) else { return nil }
        if typesenseClassification(request).tier == .safe { return [.read] }
        let routePath = String(path.unicodeScalars.prefix(while: { $0 != "?" && $0 != "#" }))
        guard let route = typesenseRoute(of: routePath) else { return nil }
        return [.named(method + " /" + typesenseTemplate(route).joined(separator: "/"))]
    }

    static func qdrantDataCommands(_ text: String) -> [DataCommand]? {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The driver answers it with a ping.
        if request.lowercased() == "select 1" { return [.read] }
        guard let parsed = QdrantConsoleParser.parse(request) else { return nil }
        if qdrantClassification(request).tier == .safe { return [.read] }
        guard var route = QdrantPathEncoding.segments(of: parsed.path) else { return nil }
        if route.count >= 2, route[0] == "collections" { route[1] = "{collection_name}" }
        return [.named(parsed.method + " /" + route.joined(separator: "/"))]
    }

    static func weaviateDataCommands(_ text: String) -> [DataCommand]? {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if weaviateClassification(request).tier == .safe { return [.read] }
        guard let parsed = WeaviateConsoleParser.parse(request), let segments = weaviateSegments(of: parsed.path) else {
            return nil
        }
        return [.named(parsed.method + " /" + weaviateTemplate(segments).joined(separator: "/"))]
    }

    static func firebaseDataCommands(_ text: String, databaseType: DatabaseType) -> [DataCommand]? {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if firebaseClassification(request, databaseType: databaseType).tier == .safe { return [.read] }
        guard case .request(let parsed)? = try? FirebaseStatement.parse(request) else { return nil }
        let segments = parsed.path.unicodeScalars.split(separator: "/").map(String.init)
        if databaseType == .firebaseRealtimeDatabase {
            return [realtimeDatabaseCommand(parsed, segments: segments)]
        }
        return [firestoreCommand(parsed, segments: segments)]
    }

    static func bigtableDataCommands(_ text: String) -> [DataCommand]? {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if bigtableClassification(request).tier == .safe { return [.read] }
        let verb = String(request.unicodeScalars.prefix(while: { !$0.properties.isWhitespace })).uppercased()
        return bigtableChanges.contains(verb) ? [.named(verb)] : nil
    }

    private static let elasticsearchMethods: Set<String> = ["GET", "POST", "PUT", "DELETE", "HEAD"]
    // Each takes a GET as well, and changes index state.
    private static let elasticsearchServerCommands: Set<String> = ["_flush", "_refresh", "_reload_search_analyzers"]
    private static let elasticsearchBulkActions: Set<String> = ["index", "create", "update", "delete"]
    private static let typesenseMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
    private static let realtimeDatabaseMetadataKeys: Set<String> = [".value", ".priority", ".sv"]
    private static let bigtableChanges: Set<String> = ["INSERT", "PUT", "DELETE"]

    private static func elasticsearchRunsServerCommand(_ route: String) -> Bool {
        route.unicodeScalars.split(separator: "/").contains { scalars in
            let segment = String(scalars)
            let name = segment.removingPercentEncoding ?? segment
            return name == "." || name == ".." || elasticsearchServerCommands.contains(name)
        }
    }

    // Nil when the URL the driver builds could reach another route: a dot segment resolves away, an empty one can
    // name another host, and a space, `%` or `\` is encoded or decoded on the way.
    private static func elasticsearchSegments(of route: String) -> [String]? {
        guard !route.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0 == "%" || $0 == "\\" }) else {
            return nil
        }
        return requestSegments(of: route)
    }

    private static func elasticsearchTemplate(_ segments: [String], api: Int) -> [String] {
        var template: [String] = Array(repeating: "{target}", count: api) + segments[api...]
        if api + 1 < segments.count, ["_doc", "_create", "_update"].contains(segments[api]) {
            template[api + 1] = "{id}"
        }
        return template
    }

    // A comma list of index names. A name starting with `.` is a system or hidden index (Elasticsearch 8.19, API
    // conventions): `.security-7`, `.watches`, `.kibana`. `+`, `-` and `<` lead an expression, `cluster:` a remote one.
    private static func elasticsearchNamesSystemIndex(_ expression: String) -> Bool {
        expression.unicodeScalars.split(separator: ",").contains { name in
            name.split(separator: ":", omittingEmptySubsequences: false).contains { part in
                part.first { $0 != "+" && $0 != "-" && $0 != "<" } == "."
            }
        }
    }

    private static func elasticsearchExpandsToHidden(_ query: String) -> Bool {
        for pair in query.unicodeScalars.split(separator: "&") {
            // The server decodes `+` in a query string as a space.
            let item = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map { String($0).replacingOccurrences(of: "+", with: " ") }
            guard let name = item[0].removingPercentEncoding else { return true }
            guard name.trimmingCharacters(in: .whitespaces).lowercased() == "expand_wildcards" else { continue }
            guard item.count == 2, let value = item[1].removingPercentEncoding else { return true }
            let states = value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if states.contains(where: { $0 == "hidden" || $0 == "all" }) { return true }
        }
        return false
    }

    // The `_index` of each action line. A source line follows every action but `delete`; a blank line is refused, since
    // the server and this reading could pair the lines differently around it.
    private static func elasticsearchBulkIndices(_ body: String) -> [String]? {
        var indices: [String] = []
        var expectsSource = false
        for line in body.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard !line.isEmpty else { return nil }
            if expectsSource {
                expectsSource = false
                continue
            }
            guard let action = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  action.count == 1, let entry = action.first, elasticsearchBulkActions.contains(entry.key),
                  let metadata = entry.value as? [String: Any]
            else { return nil }
            if let index = metadata["_index"] {
                guard let name = index as? String else { return nil }
                indices.append(name)
            }
            expectsSource = entry.key != "delete"
        }
        return expectsSource ? nil : indices
    }

    private static func typesenseTemplate(_ route: [String]) -> [String] {
        var template = route.map { $0.lowercased() }
        guard route.count >= 2, route[0] == "COLLECTIONS" else { return template }
        template[1] = "{collection}"
        if route.count == 4, route[2] == "DOCUMENTS", !["IMPORT", "EXPORT", "SEARCH"].contains(route[3]) {
            template[3] = "{id}"
        }
        return template
    }

    // Read as `WeaviatePathEncoding.resolve` sends it, which keeps a dot segment as written.
    private static func weaviateSegments(of path: String) -> [String]? {
        guard let encoded = URLComponents(string: path)?.percentEncodedPath,
              let segments = requestSegments(of: encoded)
        else { return nil }
        var decoded: [String] = []
        for segment in segments {
            guard let text = segment.removingPercentEncoding, !text.isEmpty, text != ".", text != "..",
                  !text.contains("/"), !text.contains("\\")
            else { return nil }
            decoded.append(text)
        }
        return decoded
    }

    private static func weaviateTemplate(_ segments: [String]) -> [String] {
        guard segments.count >= 3, segments[0] == "v1", segments[1] == "objects" else { return segments }
        switch segments.count {
        case 3:
            return ["v1", "objects", "{id}"]
        case 4:
            return ["v1", "objects", "{className}", "{id}"]
        case 5 where segments[3] == "references":
            return ["v1", "objects", "{id}", "references", "{propertyName}"]
        case 6 where segments[4] == "references":
            return ["v1", "objects", "{className}", "{id}", "references", "{propertyName}"]
        default:
            return segments
        }
    }

    // A key cannot hold `.`, so a segment that does names the server's own node: `/.settings/rules` holds the security
    // rules. A PATCH names each child it writes by a path of its own.
    private static func realtimeDatabaseCommand(_ request: FirebaseRequest, segments: [String]) -> DataCommand {
        if segments.contains(where: { $0.unicodeScalars.contains(".") }) { return .refused }
        if request.method == .patch {
            guard let body = request.body,
                  let members = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            else { return .refused }
            let reachesServerNode = members.keys.contains { key in
                key.unicodeScalars.split(separator: "/").contains { segment in
                    segment.contains(".") && !realtimeDatabaseMetadataKeys.contains(String(segment))
                }
            }
            if reachesServerNode { return .refused }
        }
        return .named(request.method.rawValue + " /{path}")
    }

    // Firestore refuses `.` and `..` as IDs, and the driver sends them as written, where the front end may resolve them.
    private static func firestoreCommand(_ request: FirebaseRequest, segments: [String]) -> DataCommand {
        if segments.contains(where: { $0 == "." || $0 == ".." }) { return .refused }
        guard !segments.isEmpty else { return .named(request.method.rawValue + " /") }
        return .named(request.method.rawValue + (segments.count.isMultiple(of: 2) ? " /{document}" : " /{collection}"))
    }

    // The segments after the leading `/`, one trailing `/` allowed. Nil on an empty or dot segment.
    private static func requestSegments(of route: String) -> [String]? {
        var segments = route.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.first == "" else { return nil }
        segments.removeFirst()
        if segments.last == "" { segments.removeLast() }
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return segments
    }
}

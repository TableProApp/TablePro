//
//  ElasticsearchQueryBuilder.swift
//  ElasticsearchDriverPlugin
//
//  Encodes browse and filter requests as tagged strings and builds Query DSL bodies.
//

import Foundation
import os
import TableProPluginKit

struct ElasticsearchFilterSpec: Codable, Equatable {
    let column: String
    let op: String
    let value: String
    var caseSensitive: Bool?
    var elementScope: String?

    /// Operators that matched without regard to case before a filter row could say otherwise.
    private static let ignoreCaseByDefault: Set<String> = [
        "CONTAINS", "NOT CONTAINS", "STARTS WITH", "ENDS WITH", "REGEX"
    ]

    var ignoresCase: Bool {
        guard let caseSensitive else { return Self.ignoreCaseByDefault.contains(op.uppercased()) }
        return !caseSensitive
    }
}

struct ElasticsearchSortSpec: Codable, Equatable {
    let column: String
    let ascending: Bool
}

struct ElasticsearchFieldInfo: Equatable {
    let type: String
    let hasKeywordSubfield: Bool

    /// Ancestor paths declared `nested`, outermost first, as reported by the mapping.
    let nestedPaths: [String]

    init(type: String, hasKeywordSubfield: Bool, nestedPaths: [String] = []) {
        self.type = type
        self.hasKeywordSubfield = hasKeywordSubfield
        self.nestedPaths = nestedPaths
    }
}

/// A clause and whether the filter asks for its opposite. The two travel together because a
/// negation has to be applied outside the `nested` query rather than inside it.
struct ElasticsearchClause {
    let query: [String: Any]
    let negated: Bool

    static func positive(_ query: [String: Any]) -> ElasticsearchClause {
        ElasticsearchClause(query: query, negated: false)
    }

    static func negated(_ query: [String: Any]) -> ElasticsearchClause {
        ElasticsearchClause(query: query, negated: true)
    }
}

struct ElasticsearchParsedSearch: Equatable {
    let index: String
    let from: Int
    let size: Int
    let sorts: [ElasticsearchSortSpec]
    let filters: [ElasticsearchFilterSpec]
    let logicMode: String
}

struct ElasticsearchQueryBuilder {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ElasticsearchQueryBuilder")

    static let searchTag = "ELASTICSEARCH_SEARCH:"

    static let rawColumn = "__RAW__"
    static let textTypes: Set<String> = ["text", "match_only_text", "search_as_you_type"]
    static let numericTypes: Set<String> = [
        "long", "integer", "short", "byte", "double", "float",
        "half_float", "scaled_float", "unsigned_long"
    ]
    static let metaColumns: Set<String> = ["_id", "_index", "_score"]

    func buildBrowseQuery(
        index: String,
        sorts: [ElasticsearchSortSpec],
        limit: Int,
        offset: Int
    ) -> String {
        Self.encodeSearch(index: index, from: offset, size: limit, sorts: sorts, filters: [], logicMode: "AND")
    }

    func buildFilteredQuery(
        index: String,
        filters: [PluginQueryFilter],
        logicMode: String,
        sorts: [ElasticsearchSortSpec],
        limit: Int,
        offset: Int
    ) -> String {
        Self.encodeSearch(
            index: index, from: offset, size: limit, sorts: sorts,
            filters: Self.specs(from: filters), logicMode: logicMode
        )
    }

    static func specs(from filters: [PluginQueryFilter]) -> [ElasticsearchFilterSpec] {
        filters.map {
            ElasticsearchFilterSpec(
                column: $0.column,
                op: $0.op,
                value: $0.value,
                caseSensitive: $0.isCaseSensitive,
                elementScope: $0.elementScope
            )
        }
    }

    // MARK: - Encoding

    static func encodeSearch(
        index: String,
        from: Int,
        size: Int,
        sorts: [ElasticsearchSortSpec],
        filters: [ElasticsearchFilterSpec],
        logicMode: String
    ) -> String {
        let b64Index = Data(index.utf8).base64EncodedString()
        let sortsJson = (try? JSONEncoder().encode(sorts)) ?? Data()
        let filtersJson = (try? JSONEncoder().encode(filters)) ?? Data()
        let b64Sorts = sortsJson.base64EncodedString()
        let b64Filters = filtersJson.base64EncodedString()
        let b64Logic = Data(logicMode.utf8).base64EncodedString()
        return "\(searchTag)\(b64Index):\(from):\(size):\(b64Sorts):\(b64Filters):\(b64Logic)"
    }

    static func parseSearch(_ query: String) -> ElasticsearchParsedSearch? {
        guard query.hasPrefix(searchTag) else { return nil }
        let body = String(query.dropFirst(searchTag.count))
        let parts = body.components(separatedBy: ":")
        guard parts.count >= 6,
              let indexData = Data(base64Encoded: parts[0]),
              let index = String(data: indexData, encoding: .utf8),
              let from = Int(parts[1]),
              let size = Int(parts[2])
        else { return nil }

        let sorts: [ElasticsearchSortSpec]
        if let data = Data(base64Encoded: parts[3]),
           let decoded = try? JSONDecoder().decode([ElasticsearchSortSpec].self, from: data) {
            sorts = decoded
        } else {
            sorts = []
        }

        let filters: [ElasticsearchFilterSpec]
        if let data = Data(base64Encoded: parts[4]),
           let decoded = try? JSONDecoder().decode([ElasticsearchFilterSpec].self, from: data) {
            filters = decoded
        } else {
            filters = []
        }

        let logicMode = (Data(base64Encoded: parts[5]).flatMap { String(data: $0, encoding: .utf8) }) ?? "AND"

        return ElasticsearchParsedSearch(
            index: index, from: from, size: size, sorts: sorts, filters: filters, logicMode: logicMode
        )
    }

    static func isTaggedQuery(_ query: String) -> Bool {
        query.hasPrefix(searchTag)
    }

    /// The data grid appends a SQL `ORDER BY` clause to the opaque tagged query when the
    /// user sorts a column. Split it off and parse it into sort specs.
    static func extractOrderBy(_ query: String) -> (base: String, sorts: [ElasticsearchSortSpec]) {
        guard let range = query.range(of: " ORDER BY ", options: .caseInsensitive) else {
            return (query, [])
        }
        let base = String(query[..<range.lowerBound])
        var clause = String(query[range.upperBound...])
        for keyword in [" LIMIT ", " OFFSET ", ";"] {
            if let stop = clause.range(of: keyword, options: .caseInsensitive) {
                clause = String(clause[..<stop.lowerBound])
            }
        }
        return (base, parseOrderByClause(clause))
    }

    static func parseOrderByClause(_ clause: String) -> [ElasticsearchSortSpec] {
        clause.split(separator: ",").compactMap { rawPart in
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { return nil }

            let column: String
            var remainder: Substring
            if part.hasPrefix("\"") {
                let afterQuote = part.dropFirst()
                guard let closing = afterQuote.firstIndex(of: "\"") else { return nil }
                column = String(afterQuote[..<closing])
                remainder = afterQuote[afterQuote.index(after: closing)...]
            } else {
                let tokens = part.split(separator: " ", maxSplits: 1)
                column = String(tokens[0])
                remainder = tokens.count > 1 ? tokens[1] : ""
            }

            let ascending = !remainder.uppercased().contains("DESC")
            return ElasticsearchSortSpec(column: column, ascending: ascending)
        }
    }

    // MARK: - Query DSL Construction

    static func searchBody(
        for parsed: ElasticsearchParsedSearch,
        fields: [String: ElasticsearchFieldInfo],
        size: Int,
        tiebreaker: Bool = false,
        searchAfter: [Any]? = nil,
        supportsCaseInsensitive: Bool = true
    ) -> [String: Any] {
        var body: [String: Any] = ["size": size]
        body["query"] = queryClause(
            filters: parsed.filters, logicMode: parsed.logicMode, fields: fields,
            supportsCaseInsensitive: supportsCaseInsensitive
        )
        body["sort"] = sortClause(parsed.sorts, fields: fields, tiebreaker: tiebreaker)
        if let searchAfter {
            body["search_after"] = searchAfter
        }
        return body
    }

    static func queryClause(
        filters: [ElasticsearchFilterSpec],
        logicMode: String,
        fields: [String: ElasticsearchFieldInfo],
        supportsCaseInsensitive: Bool = true
    ) -> [String: Any] {
        let active = filters.filter { !($0.column == rawColumn && $0.value.trimmingCharacters(in: .whitespaces).isEmpty) }
        guard !active.isEmpty else { return ["match_all": [String: Any]()] }

        let clauses = groupedClauses(
            filters: active, logicMode: logicMode, fields: fields,
            supportsCaseInsensitive: supportsCaseInsensitive
        )
        guard !clauses.isEmpty else { return ["match_all": [String: Any]()] }
        return combine(clauses, logicMode: logicMode)
    }

    /// Filters bound to one element of one array. The scope alone cannot key the group: the UI
    /// names a top-level array prefix, and two leaves under it can sit at different `nested`
    /// depths, whose scopes are different Lucene documents.
    private struct NestedScopeKey: Hashable {
        let scope: String
        let paths: [String]
    }

    private static func groupedClauses(
        filters: [ElasticsearchFilterSpec],
        logicMode: String,
        fields: [String: ElasticsearchFieldInfo],
        supportsCaseInsensitive: Bool
    ) -> [[String: Any]] {
        var clauses: [[String: Any]] = []
        var scopeOrder: [NestedScopeKey] = []
        var scoped: [NestedScopeKey: [ElasticsearchFilterSpec]] = [:]

        for filter in filters {
            let info = fields[filter.column]
            if filter.column != rawColumn, info?.type == ElasticsearchMappingFlattener.nestedTypeName {
                logger.warning("Dropping filter on nested parent column \(filter.column, privacy: .public)")
                continue
            }
            let paths = info?.nestedPaths ?? []
            if let scope = filter.elementScope, !scope.isEmpty, !paths.isEmpty {
                let key = NestedScopeKey(scope: scope, paths: paths)
                if scoped[key] == nil {
                    scopeOrder.append(key)
                }
                scoped[key, default: []].append(filter)
                continue
            }
            let build = clauseBuild(for: filter, fields: fields, supportsCaseInsensitive: supportsCaseInsensitive)
            clauses.append(nested(build, paths: paths))
        }

        for key in scopeOrder {
            guard let group = scoped[key] else { continue }
            clauses.append(scopedClause(
                group, key: key, logicMode: logicMode,
                fields: fields, supportsCaseInsensitive: supportsCaseInsensitive
            ))
        }
        return clauses
    }

    /// Every member of a group is rendered inside one `nested` query, which is what binds them to
    /// the same element. A lone filter is nobody's same element, so it keeps the reading every
    /// other filter row has: a negation asks that no element match at all.
    private static func scopedClause(
        _ group: [ElasticsearchFilterSpec],
        key: NestedScopeKey,
        logicMode: String,
        fields: [String: ElasticsearchFieldInfo],
        supportsCaseInsensitive: Bool
    ) -> [String: Any] {
        let builds = group.map {
            clauseBuild(for: $0, fields: fields, supportsCaseInsensitive: supportsCaseInsensitive)
        }
        guard builds.count > 1 else {
            return nested(builds[0], paths: key.paths)
        }
        let inners = builds.map { $0.negated ? mustNot($0.query) : $0.query }
        return wrapNested(combine(inners, logicMode: logicMode), paths: key.paths)
    }

    private static func combine(_ clauses: [[String: Any]], logicMode: String) -> [String: Any] {
        if clauses.count == 1, let only = clauses.first { return only }
        let occur = logicMode.uppercased() == "OR" ? "should" : "must"
        var bool: [String: Any] = [occur: clauses]
        if occur == "should" {
            bool["minimum_should_match"] = 1
        }
        return ["bool": bool]
    }

    /// A `must_not` inside a `nested` query asks for a nested object that fails the test, which any
    /// document holding a second object satisfies, and which a document holding no array at all can
    /// never satisfy. `!=`, `NOT IN`, `NOT CONTAINS` and `IS NULL` therefore negate the whole
    /// nested query rather than its body.
    private static func nested(_ build: ElasticsearchClause, paths: [String]) -> [String: Any] {
        let wrapped = wrapNested(build.query, paths: paths)
        return build.negated ? mustNot(wrapped) : wrapped
    }

    /// `ignore_unmapped` keeps an index whose mapping lacks the path from failing the whole search:
    /// an alias spanning several indices resolves one mapping for all of them.
    private static func wrapNested(_ query: [String: Any], paths: [String]) -> [String: Any] {
        paths.reversed().reduce(query) { inner, path in
            guard !path.isEmpty else { return inner }
            return ["nested": ["path": path, "query": inner, "ignore_unmapped": true]]
        }
    }

    static func sortClause(
        _ sorts: [ElasticsearchSortSpec],
        fields: [String: ElasticsearchFieldInfo],
        tiebreaker: Bool
    ) -> [[String: Any]] {
        var result: [[String: Any]] = sorts.compactMap { sort in
            guard let field = sortableField(sort.column, fields: fields) else { return nil }
            var options: [String: Any] = ["order": sort.ascending ? "asc" : "desc"]
            if let scope = nestedSortScope(paths: fields[sort.column]?.nestedPaths ?? []) {
                options["nested"] = scope
            }
            return [field: options]
        }
        if tiebreaker {
            result.append(["_shard_doc": ["order": "asc"]])
        }
        return result
    }

    /// A sort names its scopes the way a query enters them, outermost first, each one carrying the
    /// next in its own `nested` key.
    private static func nestedSortScope(paths: [String]) -> [String: Any]? {
        guard let path = paths.first, !path.isEmpty else { return nil }
        var scope: [String: Any] = ["path": path]
        if let inner = nestedSortScope(paths: Array(paths.dropFirst())) {
            scope["nested"] = inner
        }
        return scope
    }

    // MARK: - Field Resolution

    /// Returns the field to sort on, or nil when the column cannot be sorted (sorting it would
    /// raise a fielddata error and fail the whole query). `_id` is not sortable in Elasticsearch;
    /// a `text` field is sortable only through its `.keyword` sub-field.
    static func sortableField(_ column: String, fields: [String: ElasticsearchFieldInfo]) -> String? {
        if column == "_id" { return nil }
        if column == "_score" || column == "_index" { return column }
        guard let info = fields[column] else { return nil }
        if info.type == ElasticsearchMappingFlattener.nestedTypeName { return nil }
        if textTypes.contains(info.type) {
            return info.hasKeywordSubfield ? "\(column).keyword" : nil
        }
        return column
    }

    private static func matchableKeywordField(_ column: String, fields: [String: ElasticsearchFieldInfo]) -> String? {
        guard let info = fields[column] else { return column }
        if textTypes.contains(info.type) {
            return info.hasKeywordSubfield ? "\(column).keyword" : nil
        }
        return column
    }

    private static func isTextField(_ column: String, fields: [String: ElasticsearchFieldInfo]) -> Bool {
        guard let info = fields[column] else { return false }
        return textTypes.contains(info.type)
    }

    // MARK: - Per-Filter Clause

    /// `supportsCaseInsensitive` reports whether the cluster understands the `case_insensitive`
    /// option, added in 7.10. It gates what may be sent, never what the filter asked for.
    static func clause(
        for filter: ElasticsearchFilterSpec,
        fields: [String: ElasticsearchFieldInfo],
        supportsCaseInsensitive: Bool = true
    ) -> [String: Any] {
        let build = clauseBuild(for: filter, fields: fields, supportsCaseInsensitive: supportsCaseInsensitive)
        return build.negated ? mustNot(build.query) : build.query
    }

    static func clauseBuild(
        for filter: ElasticsearchFilterSpec,
        fields: [String: ElasticsearchFieldInfo],
        supportsCaseInsensitive: Bool = true
    ) -> ElasticsearchClause {
        let column = filter.column
        let op = filter.op.uppercased()
        let value = filter.value
        let ignoresCase = filter.ignoresCase
        let sendsOption = ignoresCase && supportsCaseInsensitive

        if column == rawColumn {
            return .positive(["query_string": ["query": value, "lenient": true]])
        }

        switch op {
        case "=":
            return .positive(equalsClause(column: column, value: value, fields: fields, caseInsensitive: sendsOption))
        case "!=", "<>":
            return .negated(equalsClause(column: column, value: value, fields: fields, caseInsensitive: sendsOption))
        case ">":
            return .positive(["range": [column: ["gt": typedValue(value, column: column, fields: fields)]]])
        case ">=":
            return .positive(["range": [column: ["gte": typedValue(value, column: column, fields: fields)]]])
        case "<":
            return .positive(["range": [column: ["lt": typedValue(value, column: column, fields: fields)]]])
        case "<=":
            return .positive(["range": [column: ["lte": typedValue(value, column: column, fields: fields)]]])
        case "BETWEEN":
            let bounds = value.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard bounds.count == 2 else {
                return .positive(equalsClause(column: column, value: value, fields: fields))
            }
            return .positive(["range": [column: [
                "gte": typedValue(bounds[0], column: column, fields: fields),
                "lte": typedValue(bounds[1], column: column, fields: fields),
            ]]])
        case "CONTAINS":
            return .positive(containsClause(
                column: column, value: value, fields: fields,
                ignoresCase: ignoresCase, sendsOption: sendsOption
            ))
        case "NOT CONTAINS":
            return .negated(containsClause(
                column: column, value: value, fields: fields,
                ignoresCase: ignoresCase, sendsOption: sendsOption
            ))
        case "STARTS WITH":
            if isTextField(column, fields: fields), ignoresCase {
                return .positive(["match_phrase_prefix": [column: value]])
            }
            return .positive(prefixClause(
                keywordField(column, fields: fields), value: value, caseInsensitive: sendsOption
            ))
        case "ENDS WITH":
            return .positive(wildcardClause(
                keywordField(column, fields: fields),
                pattern: "*\(escapeWildcard(value))",
                caseInsensitive: sendsOption
            ))
        case "IN":
            return .positive(listClause(column: column, value: value, fields: fields, caseInsensitive: sendsOption))
        case "NOT IN":
            return .negated(listClause(column: column, value: value, fields: fields, caseInsensitive: sendsOption))
        case "REGEX":
            return .positive(regexpClause(
                keywordField(column, fields: fields), value: value, caseInsensitive: sendsOption
            ))
        case "IS NULL", "IS_NULL", "IS EMPTY", "IS_EMPTY":
            return .negated(presentClause(column: column, fields: fields))
        case "IS NOT NULL", "IS_NOT_NULL", "IS NOT EMPTY", "IS_NOT_EMPTY":
            return .positive(presentClause(column: column, fields: fields))
        default:
            return .positive(equalsClause(column: column, value: value, fields: fields))
        }
    }

    /// The one predicate both emptiness operators are built from. Asking for absence as the
    /// negation of presence is what lets a nested leaf answer for a document that holds no array
    /// at all, which has no nested object for an `exists` to miss.
    private static func presentClause(
        column: String,
        fields: [String: ElasticsearchFieldInfo]
    ) -> [String: Any] {
        ["bool": [
            "must": [["exists": ["field": column]]],
            "must_not": [["term": [keywordField(column, fields: fields): ""]]],
        ]]
    }

    /// A text field is analyzed, so `match` already disregards case on every server version.
    /// Only the keyword path needs the option, and therefore the version gate.
    private static func containsClause(
        column: String, value: String, fields: [String: ElasticsearchFieldInfo],
        ignoresCase: Bool, sendsOption: Bool
    ) -> [String: Any] {
        if isTextField(column, fields: fields), ignoresCase {
            return ["match": [column: value]]
        }
        return wildcardClause(
            keywordField(column, fields: fields),
            pattern: "*\(escapeWildcard(value))*",
            caseInsensitive: sendsOption
        )
    }

    private static func wildcardClause(_ field: String, pattern: String, caseInsensitive: Bool) -> [String: Any] {
        var options: [String: Any] = ["value": pattern]
        if caseInsensitive { options["case_insensitive"] = true }
        return ["wildcard": [field: options]]
    }

    private static func prefixClause(_ field: String, value: String, caseInsensitive: Bool) -> [String: Any] {
        var options: [String: Any] = ["value": value]
        if caseInsensitive { options["case_insensitive"] = true }
        return ["prefix": [field: options]]
    }

    private static func regexpClause(_ field: String, value: String, caseInsensitive: Bool) -> [String: Any] {
        var options: [String: Any] = ["value": value]
        if caseInsensitive { options["case_insensitive"] = true }
        return ["regexp": [field: options]]
    }

    private static func mustNot(_ clause: [String: Any]) -> [String: Any] {
        ["bool": ["must_not": [clause]]]
    }

    private static func splitList(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func equalsClause(
        column: String,
        value: String,
        fields: [String: ElasticsearchFieldInfo],
        caseInsensitive: Bool = false
    ) -> [String: Any] {
        if isTextField(column, fields: fields) {
            if let keyword = matchableKeywordField(column, fields: fields), keyword != column {
                return termClause(keyword, value: value, caseInsensitive: caseInsensitive)
            }
            return ["match_phrase": [column: value]]
        }
        guard caseInsensitive else {
            return ["term": [column: typedValue(value, column: column, fields: fields)]]
        }
        return termClause(column, value: value, caseInsensitive: true)
    }

    /// `terms` has no case_insensitive option, so an ignore-case list becomes a should of terms.
    private static func listClause(
        column: String,
        value: String,
        fields: [String: ElasticsearchFieldInfo],
        caseInsensitive: Bool
    ) -> [String: Any] {
        let field = keywordField(column, fields: fields)
        guard caseInsensitive else { return ["terms": [field: splitList(value)]] }
        let clauses = splitList(value).map { termClause(field, value: $0, caseInsensitive: true) }
        return ["bool": ["should": clauses, "minimum_should_match": 1]]
    }

    private static func termClause(_ field: String, value: String, caseInsensitive: Bool) -> [String: Any] {
        guard caseInsensitive else { return ["term": [field: value]] }
        return ["term": [field: ["value": value, "case_insensitive": true]]]
    }

    private static func keywordField(_ column: String, fields: [String: ElasticsearchFieldInfo]) -> String {
        matchableKeywordField(column, fields: fields) ?? column
    }

    static func typedValue(_ value: String, column: String, fields: [String: ElasticsearchFieldInfo]) -> Any {
        guard let info = fields[column] else { return value }
        if numericTypes.contains(info.type) {
            if let intVal = Int(value) { return intVal }
            if let doubleVal = Double(value) { return doubleVal }
            return value
        }
        if info.type == "boolean" {
            let lower = value.lowercased()
            if lower == "true" { return true }
            if lower == "false" { return false }
        }
        return value
    }

    private static func escapeWildcard(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
    }
}

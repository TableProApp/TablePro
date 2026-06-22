//
//  ElasticsearchQueryBuilder.swift
//  ElasticsearchDriverPlugin
//
//  Encodes browse and filter requests as tagged strings and builds Query DSL bodies.
//

import Foundation

struct ElasticsearchFilterSpec: Codable, Equatable {
    let column: String
    let op: String
    let value: String
}

struct ElasticsearchSortSpec: Codable, Equatable {
    let column: String
    let ascending: Bool
}

struct ElasticsearchFieldInfo: Equatable {
    let type: String
    let hasKeywordSubfield: Bool
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
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sorts: [ElasticsearchSortSpec],
        limit: Int,
        offset: Int
    ) -> String {
        let specs = filters.map { ElasticsearchFilterSpec(column: $0.column, op: $0.op, value: $0.value) }
        return Self.encodeSearch(
            index: index, from: offset, size: limit, sorts: sorts, filters: specs, logicMode: logicMode
        )
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
        caseInsensitive: Bool = true
    ) -> [String: Any] {
        var body: [String: Any] = ["size": size]
        body["query"] = queryClause(
            filters: parsed.filters, logicMode: parsed.logicMode, fields: fields, caseInsensitive: caseInsensitive
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
        caseInsensitive: Bool = true
    ) -> [String: Any] {
        let active = filters.filter { !($0.column == rawColumn && $0.value.trimmingCharacters(in: .whitespaces).isEmpty) }
        guard !active.isEmpty else { return ["match_all": [String: Any]()] }

        let clauses = active.map { clause(for: $0, fields: fields, caseInsensitive: caseInsensitive) }
        let occur = logicMode.uppercased() == "OR" ? "should" : "must"
        var bool: [String: Any] = [occur: clauses]
        if occur == "should" {
            bool["minimum_should_match"] = 1
        }
        return ["bool": bool]
    }

    static func sortClause(
        _ sorts: [ElasticsearchSortSpec],
        fields: [String: ElasticsearchFieldInfo],
        tiebreaker: Bool
    ) -> [[String: Any]] {
        var result: [[String: Any]] = sorts.compactMap { sort in
            guard let field = sortableField(sort.column, fields: fields) else { return nil }
            return [field: ["order": sort.ascending ? "asc" : "desc"]]
        }
        if tiebreaker {
            result.append(["_shard_doc": ["order": "asc"]])
        }
        return result
    }

    // MARK: - Field Resolution

    /// Returns the field to sort on, or nil when the column cannot be sorted (sorting it would
    /// raise a fielddata error and fail the whole query). `_id` is not sortable in Elasticsearch;
    /// a `text` field is sortable only through its `.keyword` sub-field.
    static func sortableField(_ column: String, fields: [String: ElasticsearchFieldInfo]) -> String? {
        if column == "_id" { return nil }
        if column == "_score" || column == "_index" { return column }
        guard let info = fields[column] else { return nil }
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

    static func clause(
        for filter: ElasticsearchFilterSpec,
        fields: [String: ElasticsearchFieldInfo],
        caseInsensitive: Bool = true
    ) -> [String: Any] {
        let column = filter.column
        let op = filter.op.uppercased()
        let value = filter.value

        if column == rawColumn {
            return ["query_string": ["query": value, "lenient": true]]
        }

        switch op {
        case "=":
            return equalsClause(column: column, value: value, fields: fields)
        case "!=", "<>":
            return mustNot(equalsClause(column: column, value: value, fields: fields))
        case ">":
            return ["range": [column: ["gt": typedValue(value, column: column, fields: fields)]]]
        case ">=":
            return ["range": [column: ["gte": typedValue(value, column: column, fields: fields)]]]
        case "<":
            return ["range": [column: ["lt": typedValue(value, column: column, fields: fields)]]]
        case "<=":
            return ["range": [column: ["lte": typedValue(value, column: column, fields: fields)]]]
        case "BETWEEN":
            let bounds = value.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard bounds.count == 2 else { return equalsClause(column: column, value: value, fields: fields) }
            return ["range": [column: [
                "gte": typedValue(bounds[0], column: column, fields: fields),
                "lte": typedValue(bounds[1], column: column, fields: fields),
            ]]]
        case "CONTAINS":
            return containsClause(column: column, value: value, fields: fields, caseInsensitive: caseInsensitive)
        case "NOT CONTAINS":
            return mustNot(containsClause(column: column, value: value, fields: fields, caseInsensitive: caseInsensitive))
        case "STARTS WITH":
            if isTextField(column, fields: fields) {
                return ["match_phrase_prefix": [column: value]]
            }
            return prefixClause(keywordField(column, fields: fields), value: value, caseInsensitive: caseInsensitive)
        case "ENDS WITH":
            return wildcardClause(keywordField(column, fields: fields), pattern: "*\(escapeWildcard(value))", caseInsensitive: caseInsensitive)
        case "IN":
            return ["terms": [keywordField(column, fields: fields): splitList(value)]]
        case "NOT IN":
            return mustNot(["terms": [keywordField(column, fields: fields): splitList(value)]])
        case "REGEX":
            return regexpClause(keywordField(column, fields: fields), value: value, caseInsensitive: caseInsensitive)
        case "IS NULL", "IS_NULL", "IS EMPTY", "IS_EMPTY":
            return ["bool": [
                "should": [mustNot(["exists": ["field": column]]), ["term": [keywordField(column, fields: fields): ""]]],
                "minimum_should_match": 1,
            ]]
        case "IS NOT NULL", "IS_NOT_NULL", "IS NOT EMPTY", "IS_NOT_EMPTY":
            return ["bool": [
                "must": [["exists": ["field": column]]],
                "must_not": [["term": [keywordField(column, fields: fields): ""]]],
            ]]
        default:
            return equalsClause(column: column, value: value, fields: fields)
        }
    }

    private static func containsClause(
        column: String, value: String, fields: [String: ElasticsearchFieldInfo], caseInsensitive: Bool
    ) -> [String: Any] {
        if isTextField(column, fields: fields) {
            return ["match": [column: value]]
        }
        return wildcardClause(keywordField(column, fields: fields), pattern: "*\(escapeWildcard(value))*", caseInsensitive: caseInsensitive)
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
        fields: [String: ElasticsearchFieldInfo]
    ) -> [String: Any] {
        if isTextField(column, fields: fields) {
            if let keyword = matchableKeywordField(column, fields: fields), keyword != column {
                return ["term": [keyword: value]]
            }
            return ["match_phrase": [column: value]]
        }
        return ["term": [column: typedValue(value, column: column, fields: fields)]]
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

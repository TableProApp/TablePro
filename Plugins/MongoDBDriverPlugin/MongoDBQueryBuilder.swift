//
//  MongoDBQueryBuilder.swift
//  MongoDBDriverPlugin
//
//  Builds MongoDB Shell syntax query strings for collection browsing.
//  Plugin-local version using primitive types instead of Core types.
//

import Foundation
import TableProPluginKit

struct MongoDBQueryBuilder {
    /// A filter row whose column is this sentinel carries a whole filter document as its value,
    /// typed by the user, instead of a field name and an operator.
    static let rawFilterColumn = "__RAW__"

    /// Matches no document, on any collection, without a collection scan. Emitted when every
    /// condition of a non-empty filter had to be dropped, because widening to the whole
    /// collection would report success while showing rows the filter excludes.
    static let impossibleFilter = "{\"_id\": {\"$in\": []}}"

    let columnKinds: [String: BsonValueKind]

    init(columnKinds: [String: BsonValueKind] = [:]) {
        self.columnKinds = columnKinds
    }

    // MARK: - Base Query

    /// Build: db.collection.find({}).sort({}).skip(offset).limit(limit)
    func buildBaseQuery(
        collection: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)] = [],
        columns: [String] = [],
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        decorate(
            "\(Self.mongoCollectionAccessor(collection)).find({})",
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    /// Build: db.collection.find({filter}).sort({}).skip(offset).limit(limit)
    func buildFilteredQuery(
        collection: String,
        queryFilters: [PluginQueryFilter],
        logicMode: String = "and",
        sortColumns: [(columnIndex: Int, ascending: Bool)] = [],
        columns: [String] = [],
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        let filterDoc = buildFilterDocument(from: queryFilters, logicMode: logicMode)
        return decorate(
            "\(Self.mongoCollectionAccessor(collection)).find(\(filterDoc))",
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    private func decorate(
        _ query: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String {
        var result = query

        if let sort = buildSortDocument(sortColumns: sortColumns, columns: columns) {
            result += ".sort(\(sort))"
        }

        if offset > 0 {
            result += ".skip(\(offset))"
        }

        result += ".limit(\(limit))"
        return result
    }

    // MARK: - Count Query

    /// Build: db.collection.countDocuments({filter})
    func buildCountQuery(collection: String, filterJson: String = "{}") -> String {
        "\(Self.mongoCollectionAccessor(collection)).countDocuments(\(filterJson))"
    }

    // MARK: - Export Query

    func buildExportQuery(collection: String) -> String {
        "\(Self.mongoCollectionAccessor(collection)).find({})"
    }

    // MARK: - Filter Document

    /// Convert filter rows to a MongoDB filter document string.
    ///
    /// Rows carrying an `elementScope` collapse into one `$elemMatch` per array prefix, so their
    /// conditions have to hold on the *same* element. Rows without one stay independent, which is
    /// what dot notation on an array already means: any element may satisfy each condition.
    func buildFilterDocument(
        from filters: [PluginQueryFilter],
        logicMode: String = "and"
    ) -> String {
        guard !filters.isEmpty else { return "{}" }

        var clauses: [MongoDBFilterClause] = []
        var scopeOrder: [String] = []
        var scoped: [String: [PluginQueryFilter]] = [:]

        for filter in filters {
            guard filter.column != Self.rawFilterColumn else {
                if let raw = rawFilterClause(for: filter) {
                    clauses.append(raw)
                }
                continue
            }
            guard let scope = filter.elementScope, !scope.isEmpty else {
                if let clause = buildClause(for: filter, field: filter.column) {
                    clauses.append(clause)
                }
                continue
            }
            if scoped[scope] == nil {
                scopeOrder.append(scope)
            }
            scoped[scope, default: []].append(filter)
        }

        for scope in scopeOrder {
            guard let clause = elementMatchClause(
                scope: scope, filters: scoped[scope] ?? [], logicMode: logicMode
            ) else { continue }
            clauses.append(clause)
        }

        guard !clauses.isEmpty else { return Self.impossibleFilter }

        if clauses.count == 1 {
            return "{\(clauses[0].json)}"
        }

        let logicOp = logicMode == "and" ? "$and" : "$or"
        let conditionDocs = clauses.map { "{\($0.json)}" }
        return "{\"\(logicOp)\": [\(conditionDocs.joined(separator: ", "))]}"
    }

    // MARK: - Private Helpers

    /// The row's text is a whole filter document. `{}` is left to stand: it is MongoDB's own
    /// spelling for "match everything", so refusing it would invert what the user asked for.
    /// It is wrapped rather than returned bare so it can be combined with the other rows.
    private func rawFilterClause(for filter: PluginQueryFilter) -> MongoDBFilterClause? {
        guard filter.column == Self.rawFilterColumn else { return nil }
        let trimmed = filter.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        return MongoDBFilterClause(key: "$and", body: "[\(trimmed)]")
    }

    /// One `$elemMatch` per array prefix. Every condition is re-keyed to its path relative to the
    /// prefix, because `$elemMatch` matches against an element, not against the document.
    ///
    /// The panel's logic mode applies inside the group as well as between the rows: under "match
    /// any", the user asked for one element satisfying any of these rows, not all of them.
    private func elementMatchClause(
        scope: String,
        filters: [PluginQueryFilter],
        logicMode: String
    ) -> MongoDBFilterClause? {
        let inner = filters.compactMap { filter -> MongoDBFilterClause? in
            buildClause(for: filter, field: Self.relativePath(filter.column, under: scope))
        }
        guard !inner.isEmpty else { return nil }

        let body: String
        if logicMode == "and" || inner.count == 1 {
            guard let merged = MongoDBFilterClause.merge(inner) else { return nil }
            body = "{\(merged)}"
        } else {
            let docs = inner.map { "{\($0.json)}" }
            body = "{\"$or\": [\(docs.joined(separator: ", "))]}"
        }
        return MongoDBFilterClause(
            key: Self.escapeJsonString(scope),
            body: "{\"$elemMatch\": \(body)}"
        )
    }

    static func relativePath(_ column: String, under scope: String) -> String {
        let prefix = scope + "."
        guard column.hasPrefix(prefix) else { return column }
        return String(column.dropFirst(prefix.count))
    }

    private static func mongoCollectionAccessor(_ name: String) -> String {
        guard let firstChar = name.first,
              !firstChar.isNumber,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return "db[\"\(escapeJsonString(name))\"]"
        }
        return "db.\(name)"
    }

    private func buildClause(for filter: PluginQueryFilter, field rawField: String) -> MongoDBFilterClause? {
        let kind = columnKinds[filter.column]
        let field = Self.escapeJsonString(rawField)
        let ignoresCase = !filter.isCaseSensitive && MongoDBFilterValue.supportsRegexMatching(kind)
        let value = filter.value

        switch filter.op {
        case "=":
            if let binary = MongoDBUuidCodec.extendedJsonFromWrapper(value) {
                return MongoDBFilterClause(key: field, body: binary)
            }
            if kind == nil, let oid = MongoDBFilterValue.objectIdJson(value) {
                let alternatives = "[{\"\(field)\": \(oid)}, {\"\(field)\": \(typed(value, kind))}]"
                return MongoDBFilterClause(key: "$or", body: alternatives)
            }
            guard ignoresCase else { return MongoDBFilterClause(key: field, body: typed(value, kind)) }
            return MongoDBFilterClause(
                key: field, body: Self.regexBody(pattern: anchoredPattern(value), ignoresCase: true)
            )
        case "!=":
            if let binary = MongoDBUuidCodec.extendedJsonFromWrapper(value) {
                return MongoDBFilterClause(key: field, body: "{\"$ne\": \(binary)}")
            }
            if kind == nil, let oid = MongoDBFilterValue.objectIdJson(value) {
                return MongoDBFilterClause(key: field, body: "{\"$nin\": [\(oid), \(typed(value, kind))]}")
            }
            guard ignoresCase else {
                return MongoDBFilterClause(key: field, body: "{\"$ne\": \(typed(value, kind))}")
            }
            let body = Self.regexBody(pattern: anchoredPattern(value), ignoresCase: true)
            return MongoDBFilterClause(key: field, body: "{\"$not\": \(body)}")
        case ">":
            return MongoDBFilterClause(key: field, body: "{\"$gt\": \(typed(value, kind))}")
        case ">=":
            return MongoDBFilterClause(key: field, body: "{\"$gte\": \(typed(value, kind))}")
        case "<":
            return MongoDBFilterClause(key: field, body: "{\"$lt\": \(typed(value, kind))}")
        case "<=":
            return MongoDBFilterClause(key: field, body: "{\"$lte\": \(typed(value, kind))}")
        case "CONTAINS":
            return MongoDBFilterClause(
                key: field, body: Self.regexBody(pattern: escapeRegexChars(value), ignoresCase: ignoresCase)
            )
        case "NOT CONTAINS":
            let body = Self.regexBody(pattern: escapeRegexChars(value), ignoresCase: ignoresCase)
            return MongoDBFilterClause(key: field, body: "{\"$not\": \(body)}")
        case "STARTS WITH":
            let pattern = "^\(escapeRegexChars(value))"
            return MongoDBFilterClause(
                key: field, body: Self.regexBody(pattern: pattern, ignoresCase: ignoresCase)
            )
        case "ENDS WITH":
            let pattern = "\(escapeRegexChars(value))$"
            return MongoDBFilterClause(
                key: field, body: Self.regexBody(pattern: pattern, ignoresCase: ignoresCase)
            )
        case "IS NULL":
            return MongoDBFilterClause(key: field, body: "null")
        case "IS NOT NULL":
            return MongoDBFilterClause(key: field, body: "{\"$ne\": null}")
        case "IS EMPTY":
            return MongoDBFilterClause(key: field, body: "\"\"")
        case "IS NOT EMPTY":
            return MongoDBFilterClause(key: field, body: "{\"$ne\": \"\"}")
        case "REGEX":
            return MongoDBFilterClause(
                key: field, body: Self.regexBody(pattern: value, ignoresCase: ignoresCase)
            )
        case "IN":
            guard !ignoresCase else {
                return caseInsensitiveListClause(field: field, value: value)
            }
            let items = listItems(value, kind: kind)
            return MongoDBFilterClause(key: field, body: "{\"$in\": [\(items.joined(separator: ", "))]}")
        case "NOT IN":
            guard !ignoresCase else {
                return caseInsensitiveListClause(field: field, value: value, negated: true)
            }
            let items = listItems(value, kind: kind)
            return MongoDBFilterClause(key: field, body: "{\"$nin\": [\(items.joined(separator: ", "))]}")
        case "BETWEEN":
            guard let bounds = betweenBounds(filter) else { return nil }
            let body = "{\"$gte\": \(typed(bounds.lower, kind)), \"$lte\": \(typed(bounds.upper, kind))}"
            return MongoDBFilterClause(key: field, body: body)
        default:
            return nil
        }
    }

    /// `secondValue` is authoritative when the caller supplies it. `value` still arrives joined as
    /// `lower + "," + upper`, because plugins built before `secondValue` existed parse that form,
    /// so the upper bound and its separator are stripped off the end rather than split on the
    /// first comma. Splitting is only the fallback, and it cannot tell a separator from a comma
    /// inside either bound.
    private func betweenBounds(_ filter: PluginQueryFilter) -> (lower: String, upper: String)? {
        if let second = filter.secondValue {
            let upper = second.trimmingCharacters(in: .whitespaces)
            let joinedSuffix = ",\(second)"
            let lowerSource = filter.value.hasSuffix(joinedSuffix)
                ? String(filter.value.dropLast(joinedSuffix.count))
                : filter.value
            let lower = lowerSource.trimmingCharacters(in: .whitespaces)
            guard !lower.isEmpty, !upper.isEmpty else { return nil }
            return (lower, upper)
        }
        let parts = filter.value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private func buildSortDocument(
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String]
    ) -> String? {
        guard !sortColumns.isEmpty else { return nil }

        let parts = sortColumns.compactMap { sortCol -> String? in
            guard sortCol.columnIndex >= 0, sortCol.columnIndex < columns.count else { return nil }
            let columnName = Self.escapeJsonString(columns[sortCol.columnIndex])
            let direction = sortCol.ascending ? 1 : -1
            return "\"\(columnName)\": \(direction)"
        }

        guard !parts.isEmpty else { return nil }
        return "{\(parts.joined(separator: ", "))}"
    }

    private func typed(_ value: String, _ kind: BsonValueKind?) -> String {
        MongoDBFilterValue.json(value, kind: kind)
    }

    private func listItems(_ value: String, kind: BsonValueKind?) -> [String] {
        value.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .flatMap { item -> [String] in
                if kind == nil, let oid = MongoDBFilterValue.objectIdJson(item) {
                    return [oid, typed(item, kind)]
                }
                return [typed(item, kind)]
            }
    }

    private static func regexBody(pattern: String, ignoresCase: Bool) -> String {
        guard ignoresCase else { return "{\"$regex\": \"\(escapeJsonString(pattern))\"}" }
        return "{\"$regex\": \"\(escapeJsonString(pattern))\", \"$options\": \"i\"}"
    }

    private func anchoredPattern(_ value: String) -> String {
        "^\(escapeRegexChars(value))$"
    }

    /// `$in` cannot carry regex options, so an ignore-case list becomes a set of anchored matches.
    private func caseInsensitiveListClause(
        field: String,
        value: String,
        negated: Bool = false
    ) -> MongoDBFilterClause? {
        let clauses = value.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { item in
                if let binary = MongoDBUuidCodec.extendedJsonFromWrapper(item) {
                    return "{\"\(field)\": \(binary)}"
                }
                return "{\"\(field)\": \(Self.regexBody(pattern: anchoredPattern(item), ignoresCase: true))}"
            }
        guard !clauses.isEmpty else { return nil }
        let logicOp = negated ? "$nor" : "$or"
        return MongoDBFilterClause(key: logicOp, body: "[\(clauses.joined(separator: ", "))]")
    }

    static func escapeJsonString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity((value as NSString).length)
        for char in value {
            switch char {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if let ascii = char.asciiValue, ascii < 0x20 {
                    result += String(format: "\\u%04X", ascii)
                } else {
                    result.append(char)
                }
            }
        }
        return result
    }

    private func escapeRegexChars(_ str: String) -> String {
        let specialChars = "\\^$.|?*+()[]{}"
        var result = ""
        for char in str {
            if specialChars.contains(char) {
                result.append("\\")
            }
            result.append(char)
        }
        return result
    }
}

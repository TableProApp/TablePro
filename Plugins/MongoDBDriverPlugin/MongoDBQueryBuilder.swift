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
    // MARK: - Base Query

    /// Build: db.collection.find({}).sort({}).skip(offset).limit(limit)
    func buildBaseQuery(
        collection: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)] = [],
        columns: [String] = [],
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        var query = "\(Self.mongoCollectionAccessor(collection)).find({})"

        if let sort = buildSortDocument(sortColumns: sortColumns, columns: columns) {
            query += ".sort(\(sort))"
        }

        if offset > 0 {
            query += ".skip(\(offset))"
        }

        query += ".limit(\(limit))"
        return query
    }

    /// Build: db.collection.find({filter}).sort({}).skip(offset).limit(limit)
    func buildFilteredQuery(
        collection: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String = "and",
        sortColumns: [(columnIndex: Int, ascending: Bool)] = [],
        columns: [String] = [],
        limit: Int = 200,
        offset: Int = 0
    ) -> String {
        let filterDoc = buildFilterDocument(from: filters, logicMode: logicMode)
        var query = "\(Self.mongoCollectionAccessor(collection)).find(\(filterDoc))"

        if let sort = buildSortDocument(sortColumns: sortColumns, columns: columns) {
            query += ".sort(\(sort))"
        }

        if offset > 0 {
            query += ".skip(\(offset))"
        }

        query += ".limit(\(limit))"
        return query
    }

    // MARK: - Count Query

    /// Build: db.collection.countDocuments({filter})
    func buildCountQuery(collection: String, filterJson: String = "{}") -> String {
        "\(Self.mongoCollectionAccessor(collection)).countDocuments(\(filterJson))"
    }

    // MARK: - Filter Document

    /// Convert filter tuples to MongoDB filter document string
    func buildFilterDocument(
        from filters: [(column: String, op: String, value: String)],
        logicMode: String = "and"
    ) -> String {
        guard !filters.isEmpty else { return "{}" }

        let conditions = filters.compactMap { filter -> String? in
            buildCondition(column: filter.column, op: filter.op, value: filter.value)
        }

        guard !conditions.isEmpty else { return "{}" }

        if conditions.count == 1 {
            return "{\(conditions[0])}"
        }

        let logicOp = logicMode == "and" ? "$and" : "$or"
        let conditionDocs = conditions.map { "{\($0)}" }
        return "{\"\(logicOp)\": [\(conditionDocs.joined(separator: ", "))]}"
    }

    // MARK: - Private Helpers

    private static func mongoCollectionAccessor(_ name: String) -> String {
        guard let firstChar = name.first,
              !firstChar.isNumber,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return "db[\"\(escapeJsonString(name))\"]"
        }
        return "db.\(name)"
    }

    private func buildCondition(column: String, op: String, value: String) -> String? {
        let field = Self.escapeJsonString(column)

        switch op {
        case "=":
            return "\"\(field)\": \(jsonValue(value))"
        case "!=":
            return "\"\(field)\": {\"$ne\": \(jsonValue(value))}"
        case ">":
            return "\"\(field)\": {\"$gt\": \(jsonValue(value))}"
        case ">=":
            return "\"\(field)\": {\"$gte\": \(jsonValue(value))}"
        case "<":
            return "\"\(field)\": {\"$lt\": \(jsonValue(value))}"
        case "<=":
            return "\"\(field)\": {\"$lte\": \(jsonValue(value))}"
        case "CONTAINS":
            return "\"\(field)\": {\"$regex\": \"\(escapeRegexChars(value))\", \"$options\": \"i\"}"
        case "NOT CONTAINS":
            return "\"\(field)\": {\"$not\": {\"$regex\": \"\(escapeRegexChars(value))\", \"$options\": \"i\"}}"
        case "STARTS WITH":
            return "\"\(field)\": {\"$regex\": \"^\(escapeRegexChars(value))\", \"$options\": \"i\"}"
        case "ENDS WITH":
            return "\"\(field)\": {\"$regex\": \"\(escapeRegexChars(value))$\", \"$options\": \"i\"}"
        case "IS NULL":
            return "\"\(field)\": null"
        case "IS NOT NULL":
            return "\"\(field)\": {\"$ne\": null}"
        case "IS EMPTY":
            return "\"\(field)\": \"\""
        case "IS NOT EMPTY":
            return "\"\(field)\": {\"$ne\": \"\"}"
        case "REGEX":
            return "\"\(field)\": {\"$regex\": \"\(value)\", \"$options\": \"i\"}"
        case "IN":
            let items = value.split(separator: ",")
                .map { jsonValue(String($0).trimmingCharacters(in: .whitespaces)) }
            return "\"\(field)\": {\"$in\": [\(items.joined(separator: ", "))]}"
        case "NOT IN":
            let items = value.split(separator: ",")
                .map { jsonValue(String($0).trimmingCharacters(in: .whitespaces)) }
            return "\"\(field)\": {\"$nin\": [\(items.joined(separator: ", "))]}"
        case "BETWEEN":
            let parts = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return nil }
            return "\"\(field)\": {\"$gte\": \(jsonValue(parts[0])), \"$lte\": \(jsonValue(parts[1]))}"
        default:
            return nil
        }
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

    /// Auto-detect value type for JSON representation
    private func jsonValue(_ value: String) -> String {
        if value == "true" || value == "false" { return value }
        if value == "null" { return value }
        if Int64(value) != nil { return value }
        if Double(value) != nil, value.contains(".") { return value }
        return "\"\(Self.escapeJsonString(value))\""
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

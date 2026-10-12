import Foundation
import TableProPluginKit

/// Lays schemaless items out as a grid.
///
/// Columns are the columns the grid already shows, in its order, then the table's key attributes,
/// then every other attribute any item carries, alphabetically. Keeping the grid's order is what
/// lets Data Rewind read a row back by position.
struct DynamoDBItemTable: Sendable {
    let columns: [String]
    let types: [DynamoDBAttributeType?]
    let rows: [[PluginCellValue]]

    init(
        items: [DynamoDBItem],
        schema: DynamoDBTableSchema?,
        preferredColumns: [String] = [],
        includeAllKeys: Bool = true
    ) {
        var columns: [String] = []
        var seen = Set<String>()
        func add(_ name: String) {
            guard seen.insert(name).inserted else { return }
            columns.append(name)
        }
        preferredColumns.forEach(add)
        schema?.keys.attributes
            .filter { key in includeAllKeys || items.contains { $0[key] != nil } }
            .forEach(add)
        var remaining = Set<String>()
        for item in items {
            for name in item.keys where !seen.contains(name) {
                remaining.insert(name)
            }
        }
        remaining.sorted().forEach(add)

        self.columns = columns
        self.types = columns.map { column in
            if let keyType = schema?.keyType(of: column), schema?.keys.attributes.contains(column) == true {
                return keyType
            }
            return Self.majorityType(of: column, in: items)
        }
        self.rows = items.map { item in
            columns.map { DynamoDBCellCodec.cell(for: item[$0]) }
        }
    }

    var typeNames: [String] {
        types.map { $0?.displayName ?? DynamoDBAttributeType.string.displayName }
    }

    /// Carries the type the app classifies each column by, so a Map, a List or a set opens in the
    /// JSON editor while the header still reads Map.
    func columnMeta(schema: DynamoDBTableSchema?) -> [PluginColumnInfo] {
        zip(columns, types).map { column, type in
            let resolved = type ?? .string
            let isKey = schema?.keys.attributes.contains(column) ?? false
            return PluginColumnInfo(
                name: column,
                dataType: resolved.displayName,
                isNullable: !isKey,
                isPrimaryKey: isKey,
                defaultValue: nil,
                extra: nil,
                charset: nil,
                collation: nil,
                comment: nil,
                identityKind: nil,
                isGenerated: false,
                allowedValues: nil,
                generationExpression: nil,
                generationKind: nil,
                ddlSpelling: nil,
                ddlDefault: nil,
                ddlGenerationExpression: nil,
                ddlCollation: nil,
                classificationTypeName: resolved.classificationName
            )
        }
    }

    var observedTypes: [String: DynamoDBAttributeType] {
        var result: [String: DynamoDBAttributeType] = [:]
        for (column, type) in zip(columns, types) {
            if let type { result[column] = type }
        }
        return result
    }

    static func majorityType(of attribute: String, in items: [DynamoDBItem]) -> DynamoDBAttributeType? {
        var counts: [DynamoDBAttributeType: Int] = [:]
        for item in items {
            guard let value = item[attribute], value != .null else { continue }
            counts[value.type, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
        }?.key
    }

    /// Sorts items for an ORDER BY DynamoDB could not apply. Numbers compare as numbers, missing
    /// values sort first, and ties keep DynamoDB's order.
    static func sorted(_ items: [DynamoDBItem], by order: [DynamoDBOrderTerm]) -> [DynamoDBItem] {
        items.enumerated().sorted { lhs, rhs in
            for term in order {
                let comparison = compare(lhs.element[term.attribute], rhs.element[term.attribute])
                guard comparison != .orderedSame else { continue }
                return term.descending ? comparison == .orderedDescending : comparison == .orderedAscending
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func typeRank(_ value: DynamoDBAttributeValue) -> Int {
        switch value.type {
        case .null: return 0
        case .boolean: return 1
        case .number: return 2
        case .string: return 3
        case .binary: return 4
        default: return 5
        }
    }

    private static func compare(_ lhs: DynamoDBAttributeValue?, _ rhs: DynamoDBAttributeValue?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case (.number(let left)?, .number(let right)?): return DynamoDBNumber.compare(left, right)
        case (let left?, let right?) where typeRank(left) != typeRank(right):
            return typeRank(left) < typeRank(right) ? .orderedAscending : .orderedDescending
        case (let left?, let right?):
            let leftText = DynamoDBCellCodec.displayText(for: left)
            let rightText = DynamoDBCellCodec.displayText(for: right)
            return leftText < rightText ? .orderedAscending : (leftText == rightText ? .orderedSame : .orderedDescending)
        }
    }
}

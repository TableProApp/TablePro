//
//  EtcdRowFilter.swift
//  EtcdDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum EtcdColumn: String, Codable, CaseIterable, Sendable {
    case key = "Key"
    case value = "Value"
    case version = "Version"
    case modRevision = "ModRevision"
    case createRevision = "CreateRevision"
    case lease = "Lease"
}

internal enum EtcdComparison: String, Codable, CaseIterable, Sendable {
    case equal = "="
    case notEqual = "!="
    case contains = "CONTAINS"
    case notContains = "NOT CONTAINS"
    case startsWith = "STARTS WITH"
    case endsWith = "ENDS WITH"
    case greaterThan = ">"
    case greaterOrEqual = ">="
    case lessThan = "<"
    case lessOrEqual = "<="
    case isNull = "IS NULL"
    case isNotNull = "IS NOT NULL"
    case isEmpty = "IS EMPTY"
    case isNotEmpty = "IS NOT EMPTY"
    case inList = "IN"
    case notInList = "NOT IN"
    case between = "BETWEEN"
    case regex = "REGEX"
}

internal struct EtcdFilterRefusal: Error, Equatable, PluginDriverError {
    let pluginErrorMessage: String

    static let rawCondition = EtcdFilterRefusal(pluginErrorMessage: String(
        localized: "etcd cannot filter with a raw SQL condition."
    ))

    static let incompleteRange = EtcdFilterRefusal(pluginErrorMessage: String(
        localized: "Enter both bounds to filter with BETWEEN."
    ))

    static let leaseOperand = EtcdFilterRefusal(pluginErrorMessage: String(
        localized: "Lease can only be compared with a lease ID, such as 0x7b."
    ))

    static func unknownColumn(_ column: String) -> EtcdFilterRefusal {
        EtcdFilterRefusal(pluginErrorMessage: String(format: String(localized: "etcd has no %@ column."), column))
    }

    static func unsupportedOperator(_ op: String) -> EtcdFilterRefusal {
        EtcdFilterRefusal(pluginErrorMessage: String(format: String(localized: "etcd cannot filter with %@."), op))
    }

    static func wholeNumberOperand(_ column: EtcdColumn) -> EtcdFilterRefusal {
        EtcdFilterRefusal(pluginErrorMessage: String(
            format: String(localized: "%@ can only be compared with a whole number."), column.rawValue
        ))
    }

    static func emptyList(_ comparison: EtcdComparison) -> EtcdFilterRefusal {
        EtcdFilterRefusal(pluginErrorMessage: String(
            format: String(localized: "Enter at least one value to filter with %@."), comparison.rawValue
        ))
    }

    static func invalidPattern(_ pattern: String) -> EtcdFilterRefusal {
        EtcdFilterRefusal(pluginErrorMessage: String(
            format: String(localized: "'%@' is not a valid regular expression."), pattern
        ))
    }
}

internal struct EtcdFilterRow: Equatable, Sendable {
    let key: String
    let value: String?
    let version: String
    let modRevision: String
    let createRevision: String
    let lease: String

    var cells: [PluginCellValue] {
        EtcdColumn.allCases.map { PluginCellValue.fromOptional(text(of: $0)) }
    }

    func text(of column: EtcdColumn) -> String? {
        switch column {
        case .key: return key
        case .value: return value
        case .version: return version
        case .modRevision: return modRevision
        case .createRevision: return createRevision
        case .lease: return EtcdLeaseID.cellText(serverValue: lease)
        }
    }

    func number(of column: EtcdColumn) -> Int64? {
        switch column {
        case .key, .value: return nil
        case .version: return Int64(version)
        case .modRevision: return Int64(modRevision)
        case .createRevision: return Int64(createRevision)
        case .lease: return Int64(lease) ?? 0
        }
    }
}

internal struct EtcdRowFilter: Codable, Equatable, Sendable {
    internal struct Condition: Codable, Equatable, Sendable {
        let column: EtcdColumn
        let comparison: EtcdComparison
        let value: String
        let secondValue: String?
        let isCaseSensitive: Bool

        var searchesValueToo: Bool {
            column == .key && (comparison == .contains || comparison == .startsWith)
        }
    }

    static let rawConditionColumn = "__RAW__"
    static let unfiltered = EtcdRowFilter(conditions: [], matchesAll: true)

    let conditions: [Condition]
    let matchesAll: Bool

    var isUnfiltered: Bool { conditions.isEmpty }

    var readsValues: Bool {
        conditions.contains { $0.column == .value || $0.searchesValueToo }
    }

    init(conditions: [Condition], matchesAll: Bool) {
        self.conditions = conditions
        self.matchesAll = matchesAll
    }

    init(filters: [PluginQueryFilter], logicMode: String) throws(EtcdFilterRefusal) {
        var conditions: [Condition] = []
        for filter in filters {
            conditions.append(try Self.condition(from: filter))
        }
        self.init(conditions: conditions, matchesAll: logicMode.lowercased() != "or")
        _ = try matcher()
    }

    func matcher() throws(EtcdFilterRefusal) -> EtcdRowMatcher {
        var tests: [EtcdConditionTest] = []
        for condition in conditions {
            tests.append(try EtcdConditionTest(condition))
        }
        return EtcdRowMatcher(tests: tests, matchesAll: matchesAll)
    }

    private static func condition(from filter: PluginQueryFilter) throws(EtcdFilterRefusal) -> Condition {
        guard filter.column != rawConditionColumn else { throw .rawCondition }
        guard let column = EtcdColumn(rawValue: filter.column) else { throw .unknownColumn(filter.column) }
        let op = filter.op.trimmingCharacters(in: .whitespaces).uppercased()
        guard let comparison = EtcdComparison(rawValue: op) else { throw .unsupportedOperator(filter.op) }
        return Condition(
            column: column,
            comparison: comparison,
            value: filter.value,
            secondValue: filter.secondValue,
            isCaseSensitive: filter.isCaseSensitive
        )
    }
}

internal struct EtcdRowMatcher {
    fileprivate let tests: [EtcdConditionTest]
    fileprivate let matchesAll: Bool

    func matches(_ row: EtcdFilterRow) -> Bool {
        guard !tests.isEmpty else { return true }
        return matchesAll ? tests.allSatisfy { $0.matches(row) } : tests.contains { $0.matches(row) }
    }
}

private struct EtcdConditionTest {
    private enum Operand {
        case text(String)
        case number(Int64)
    }

    private let condition: EtcdRowFilter.Condition
    private let operands: [Operand]
    private let regex: NSRegularExpression?

    init(_ condition: EtcdRowFilter.Condition) throws(EtcdFilterRefusal) {
        self.condition = condition
        switch condition.comparison {
        case .equal, .notEqual, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual:
            operands = [try Self.operand(condition.value, for: condition.column)]
            regex = nil
        case .between:
            let bounds = try Self.rangeBounds(condition)
            operands = [
                try Self.operand(bounds.lower, for: condition.column),
                try Self.operand(bounds.upper, for: condition.column),
            ]
            regex = nil
        case .inList, .notInList:
            let items = Self.listItems(condition.value)
            guard !items.isEmpty else { throw .emptyList(condition.comparison) }
            var parsed: [Operand] = []
            for item in items {
                parsed.append(try Self.operand(item, for: condition.column))
            }
            operands = parsed
            regex = nil
        case .regex:
            let options: NSRegularExpression.Options = condition.isCaseSensitive ? [] : [.caseInsensitive]
            guard let compiled = try? NSRegularExpression(pattern: condition.value, options: options) else {
                throw .invalidPattern(condition.value)
            }
            operands = []
            regex = compiled
        case .contains, .notContains, .startsWith, .endsWith, .isNull, .isNotNull, .isEmpty, .isNotEmpty:
            operands = []
            regex = nil
        }
    }

    func matches(_ row: EtcdFilterRow) -> Bool {
        let cell = row.text(of: condition.column)
        switch condition.comparison {
        case .isNull:
            return cell == nil
        case .isNotNull:
            return cell != nil
        case .isEmpty:
            return cell?.isEmpty ?? true
        case .isNotEmpty:
            return !(cell?.isEmpty ?? true)
        default:
            guard let cell else { return false }
            if matches(cell, in: row) { return true }
            guard condition.searchesValueToo, let value = row.value else { return false }
            return matches(value, in: row)
        }
    }

    private func matches(_ cell: String, in row: EtcdFilterRow) -> Bool {
        switch condition.comparison {
        case .contains:
            return finds(in: cell, anchoring: [])
        case .notContains:
            return !finds(in: cell, anchoring: [])
        case .startsWith:
            return finds(in: cell, anchoring: [.anchored])
        case .endsWith:
            return finds(in: cell, anchoring: [.anchored, .backwards])
        case .regex:
            return matchesPattern(cell)
        case .equal:
            return order(of: row, against: operands[0]) == .orderedSame
        case .notEqual:
            return order(of: row, against: operands[0]) != .orderedSame
        case .greaterThan:
            return order(of: row, against: operands[0]) == .orderedDescending
        case .greaterOrEqual:
            return order(of: row, against: operands[0]) != .orderedAscending
        case .lessThan:
            return order(of: row, against: operands[0]) == .orderedAscending
        case .lessOrEqual:
            return order(of: row, against: operands[0]) != .orderedDescending
        case .between:
            return order(of: row, against: operands[0]) != .orderedAscending
                && order(of: row, against: operands[1]) != .orderedDescending
        case .inList:
            return operands.contains { order(of: row, against: $0) == .orderedSame }
        case .notInList:
            return !operands.contains { order(of: row, against: $0) == .orderedSame }
        case .isNull, .isNotNull, .isEmpty, .isNotEmpty:
            return false
        }
    }

    private var textOptions: String.CompareOptions {
        condition.isCaseSensitive ? [.literal] : [.caseInsensitive]
    }

    private var isOrdering: Bool {
        switch condition.comparison {
        case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .between:
            return true
        default:
            return false
        }
    }

    private func finds(in cell: String, anchoring: String.CompareOptions) -> Bool {
        guard !condition.value.isEmpty else { return true }
        return cell.range(of: condition.value, options: textOptions.union(anchoring)) != nil
    }

    private func matchesPattern(_ cell: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(location: 0, length: (cell as NSString).length)
        return regex.firstMatch(in: cell, options: [], range: range) != nil
    }

    private func order(of row: EtcdFilterRow, against operand: Operand) -> ComparisonResult? {
        switch operand {
        case .number(let number):
            guard let cellNumber = row.number(of: condition.column) else { return nil }
            return Self.compare(cellNumber, number)
        case .text(let text):
            guard let cell = row.text(of: condition.column) else { return nil }
            guard isOrdering else { return cell.compare(text, options: textOptions) }
            return Self.byteOrder(cell, text)
        }
    }

    private static func compare(_ lhs: Int64, _ rhs: Int64) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func byteOrder(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.utf8.elementsEqual(rhs.utf8) { return .orderedSame }
        return lhs.utf8.lexicographicallyPrecedes(rhs.utf8) ? .orderedAscending : .orderedDescending
    }

    private static func operand(_ text: String, for column: EtcdColumn) throws(EtcdFilterRefusal) -> Operand {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch column {
        case .key, .value:
            return .text(text)
        case .version, .modRevision, .createRevision:
            guard let number = Int64(trimmed) else { throw .wholeNumberOperand(column) }
            return .number(number)
        case .lease:
            guard let leaseId = try? EtcdCommandParser.parseLeaseId(trimmed) else { throw .leaseOperand }
            return .number(leaseId)
        }
    }

    private static func listItems(_ text: String) -> [String] {
        text.split(separator: ",", omittingEmptySubsequences: true).compactMap {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func rangeBounds(
        _ condition: EtcdRowFilter.Condition
    ) throws(EtcdFilterRefusal) -> (lower: String, upper: String) {
        guard let upper = condition.secondValue, !upper.isEmpty else { throw .incompleteRange }
        let joinedSuffix = "," + upper
        let lower = condition.value.hasSuffix(joinedSuffix)
            ? String(condition.value.dropLast(joinedSuffix.count))
            : condition.value
        guard !lower.isEmpty else { throw .incompleteRange }
        return (lower, upper)
    }
}

//
//  HighlightCondition.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct HighlightCondition {
    static let searchLimit = 10_000

    private enum ValueKind {
        case numeric
        case boolean
        case text
    }

    private struct Operand {
        let text: String
        let number: Decimal?
        let boolean: Bool?
        let isNullLiteral: Bool

        init(_ raw: String, allowsNullLiteral: Bool) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            text = raw
            number = HighlightCondition.number(from: trimmed)
            boolean = StoredBoolean.value(of: trimmed)
            isNullLiteral = allowsNullLiteral && HighlightCondition.isNullKeyword(trimmed)
        }
    }

    private let filterOperator: FilterOperator
    private let valueKind: ValueKind
    private let comparesCaseInsensitively: Bool
    private let supportsEmptyString: Bool
    private let operand: Operand
    private let secondOperand: Operand
    private let listOperands: [Operand]
    private let regex: NSRegularExpression?

    init(rule: HighlightRule, columnType: ColumnType?) {
        filterOperator = rule.filterOperator
        valueKind = Self.valueKind(for: columnType)
        comparesCaseInsensitively = rule.filterOperator.supportsCaseSensitivity && !rule.isCaseSensitive
        supportsEmptyString = ColumnTypeSQLQuoting.supportsEmptyStringComparison(columnType)

        let allowsNullLiteral = Self.allowsNullLiteral(for: columnType)
        operand = Operand(rule.value, allowsNullLiteral: allowsNullLiteral)
        secondOperand = Operand(rule.secondValue ?? "", allowsNullLiteral: allowsNullLiteral)
        listOperands = rule.filterOperator == .inList || rule.filterOperator == .notInList
            ? Self.listItems(rule.value).map { Operand($0, allowsNullLiteral: allowsNullLiteral) }
            : []
        regex = rule.filterOperator == .regex
            ? Self.regularExpression(rule.value, ignoresCase: comparesCaseInsensitively)
            : nil
    }

    func matches(_ value: PluginCellValue) -> Bool {
        switch value {
        case .null:
            return matchesNull()
        case .bytes:
            return matchesBinary()
        case .text(let text):
            return matches(text: text)
        }
    }

    private func matchesNull() -> Bool {
        switch filterOperator {
        case .isNull, .isEmpty:
            return true
        case .equal:
            return operand.isNullLiteral
        case .inList:
            return listOperands.contains { $0.isNullLiteral }
        case .notEqual, .contains, .notContains, .startsWith, .endsWith, .greaterThan, .greaterOrEqual,
             .lessThan, .lessOrEqual, .isNotNull, .isNotEmpty, .notInList, .between, .regex:
            return false
        }
    }

    private func matchesBinary() -> Bool {
        switch filterOperator {
        case .isNotNull, .isNotEmpty:
            return true
        case .isNull, .isEmpty, .equal, .notEqual, .contains, .notContains, .startsWith, .endsWith,
             .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .inList, .notInList, .between, .regex:
            return false
        }
    }

    private func matches(text: String) -> Bool {
        switch filterOperator {
        case .equal:
            return !operand.isNullLiteral && order(text, against: operand) == .orderedSame
        case .notEqual:
            return operand.isNullLiteral || order(text, against: operand) != .orderedSame
        case .contains:
            return contains(text)
        case .notContains:
            return !contains(text)
        case .startsWith:
            return hasAffix(text, anchoredAtEnd: false)
        case .endsWith:
            return hasAffix(text, anchoredAtEnd: true)
        case .greaterThan:
            return !operand.isNullLiteral && order(text, against: operand) == .orderedDescending
        case .greaterOrEqual:
            return !operand.isNullLiteral && order(text, against: operand) != .orderedAscending
        case .lessThan:
            return !operand.isNullLiteral && order(text, against: operand) == .orderedAscending
        case .lessOrEqual:
            return !operand.isNullLiteral && order(text, against: operand) != .orderedDescending
        case .isNull:
            return false
        case .isNotNull:
            return true
        case .isEmpty:
            return supportsEmptyString && text.isEmpty
        case .isNotEmpty:
            return !supportsEmptyString || !text.isEmpty
        case .inList:
            return listOperands.contains { !$0.isNullLiteral && order(text, against: $0) == .orderedSame }
        case .notInList:
            let values = listOperands.filter { !$0.isNullLiteral }
            return !values.isEmpty && !values.contains { order(text, against: $0) == .orderedSame }
        case .between:
            return order(text, against: operand) != .orderedAscending
                && order(text, against: secondOperand) != .orderedDescending
        case .regex:
            return matchesRegex(text)
        }
    }

    private func order(_ text: String, against operand: Operand) -> ComparisonResult {
        if prefersNumbers, let lhs = Self.number(from: text), let rhs = operand.number {
            return Self.compare(lhs, rhs)
        }
        if prefersBooleans, let lhs = StoredBoolean.value(of: text), let rhs = operand.boolean {
            return Self.compare(lhs ? 1 : 0, rhs ? 1 : 0)
        }
        return text.compare(operand.text, options: comparesCaseInsensitively ? [.caseInsensitive] : [.literal])
    }

    private var prefersNumbers: Bool {
        switch valueKind {
        case .numeric:
            return true
        case .boolean:
            return false
        case .text:
            return isOrderingOperator
        }
    }

    private var prefersBooleans: Bool {
        switch valueKind {
        case .numeric, .boolean:
            return true
        case .text:
            return false
        }
    }

    private var isOrderingOperator: Bool {
        switch filterOperator {
        case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .between:
            return true
        case .equal, .notEqual, .contains, .notContains, .startsWith, .endsWith, .isNull, .isNotNull,
             .isEmpty, .isNotEmpty, .inList, .notInList, .regex:
            return false
        }
    }

    private var searchOptions: String.CompareOptions {
        comparesCaseInsensitively ? [.caseInsensitive] : [.literal]
    }

    private func contains(_ text: String) -> Bool {
        guard !operand.text.isEmpty else { return true }
        return Self.searchable(text).range(of: operand.text, options: searchOptions) != nil
    }

    private func hasAffix(_ text: String, anchoredAtEnd: Bool) -> Bool {
        guard !operand.text.isEmpty else { return true }
        let options = searchOptions.union(anchoredAtEnd ? [.anchored, .backwards] : [.anchored])
        return text.range(of: operand.text, options: options) != nil
    }

    private func matchesRegex(_ text: String) -> Bool {
        guard let regex else { return false }
        let searchable = Self.searchable(text) as NSString
        return regex.firstMatch(
            in: searchable as String,
            options: [],
            range: NSRange(location: 0, length: searchable.length)
        ) != nil
    }

    private static func searchable(_ text: String) -> String {
        let source = text as NSString
        guard source.length > searchLimit else { return text }
        let cut = source.rangeOfComposedCharacterSequence(at: searchLimit).location
        return source.substring(to: cut)
    }

    private static func regularExpression(_ pattern: String, ignoresCase: Bool) -> NSRegularExpression? {
        guard !pattern.isEmpty, (pattern as NSString).length <= searchLimit else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: ignoresCase ? [.caseInsensitive] : [])
    }

    private static func valueKind(for columnType: ColumnType?) -> ValueKind {
        switch columnType {
        case .integer, .decimal:
            return .numeric
        case .boolean:
            return .boolean
        case .text, .date, .timestamp, .datetime, .blob, .json, .enumType, .set, .spatial, .array, .none:
            return .text
        }
    }

    private static func listItems(_ input: String) -> [String] {
        input.split(separator: ",", omittingEmptySubsequences: true).compactMap {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static func readsAsNullLiteral(_ text: String, columnType: ColumnType?) -> Bool {
        allowsNullLiteral(for: columnType) && isNullKeyword(text.trimmingCharacters(in: .whitespaces))
    }

    private static func allowsNullLiteral(for columnType: ColumnType?) -> Bool {
        !ColumnTypeSQLQuoting.isKnownTextLike(columnType)
    }

    private static func isNullKeyword(_ text: String) -> Bool {
        text.caseInsensitiveCompare("NULL") == .orderedSame
    }

    static func number(from text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard PluginNumericLiteral.isValid(trimmed) else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func compare<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

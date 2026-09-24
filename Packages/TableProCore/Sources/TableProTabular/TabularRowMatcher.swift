import Foundation
import TableProTabularIO

public final class TabularRowMatcher: @unchecked Sendable {
    public let columns: [TabularColumnID]
    private let root: Node

    private indirect enum Node {
        case always
        case cell(CompiledCellPredicate, slot: Int)
        case all([Node])
        case any([Node])
        case search(TabularNeedle, slots: [Int])
    }

    public init(predicate: TabularRowPredicate) {
        let columns = predicate.referencedColumns
        var slots: [TabularColumnID: Int] = [:]
        for (slot, column) in columns.enumerated() {
            slots[column] = slot
        }
        self.columns = columns
        root = Self.compile(predicate, slots: slots)
    }

    public var isTrivial: Bool {
        if case .always = root { return true }
        return false
    }

    public func matches(_ cells: TabularRowCells) -> Bool {
        evaluate(root, cells)
    }

    private func evaluate(_ node: Node, _ cells: TabularRowCells) -> Bool {
        switch node {
        case .always:
            return true
        case .cell(let predicate, let slot):
            return predicate.matches(kind: cells.kinds[slot], bytes: cells.bytes[slot])
        case .all(let parts):
            for part in parts where !evaluate(part, cells) {
                return false
            }
            return true
        case .any(let parts):
            guard !parts.isEmpty else { return true }
            for part in parts where evaluate(part, cells) {
                return true
            }
            return false
        case .search(let needle, let slots):
            guard !needle.isEmpty else { return true }
            for slot in slots where TabularTextMatching.contains(
                cells.bytes[slot],
                needle,
                caseSensitive: false,
                diacriticSensitive: false
            ) {
                return true
            }
            return false
        }
    }

    private static func compile(_ predicate: TabularRowPredicate, slots: [TabularColumnID: Int]) -> Node {
        switch predicate {
        case .always:
            return .always
        case .cell(let cell):
            guard let slot = slots[cell.column] else { return .always }
            return .cell(CompiledCellPredicate(cell), slot: slot)
        case .all(let parts):
            let compiled = parts.map { compile($0, slots: slots) }.filter {
                if case .always = $0 { return false }
                return true
            }
            if compiled.isEmpty { return .always }
            return compiled.count == 1 ? compiled[0] : .all(compiled)
        case .any(let parts):
            let compiled = parts.map { compile($0, slots: slots) }
            if compiled.isEmpty { return .always }
            return compiled.count == 1 ? compiled[0] : .any(compiled)
        case .search(let search):
            let needle = TabularNeedle(search.text)
            guard !needle.isEmpty else { return .always }
            return .search(needle, slots: search.columns.compactMap { slots[$0] })
        }
    }
}

struct CompiledCellPredicate {
    private struct Operand {
        let needle: TabularNeedle
        let number: Double?
        let boolean: Bool?
        let isNullLiteral: Bool

        init(_ operand: TabularOperand) {
            needle = TabularNeedle(operand.text)
            number = operand.number
            boolean = operand.boolean
            isNullLiteral = operand.isNullLiteral
        }
    }

    private let comparison: TabularComparison
    private let valueKind: TabularValueKind
    private let caseSensitive: Bool
    private let operand: Operand
    private let secondOperand: Operand
    private let listOperands: [Operand]
    private let regex: NSRegularExpression?

    init(_ predicate: TabularCellPredicate) {
        comparison = predicate.comparison
        valueKind = predicate.valueKind
        caseSensitive = predicate.isCaseSensitive
        operand = Operand(predicate.operand)
        secondOperand = Operand(predicate.secondOperand)
        listOperands = predicate.listOperands.map(Operand.init)
        regex = predicate.comparison == .regex
            ? Self.regularExpression(predicate.operand.text, caseSensitive: predicate.isCaseSensitive)
            : nil
    }

    static func regularExpression(_ pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }

    func matches(kind: TabularCellKind, bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !kind.isNullLike else { return matchesNull() }
        return matches(text: bytes)
    }

    private func matchesNull() -> Bool {
        switch comparison {
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

    private func matches(text bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        switch comparison {
        case .equal:
            return !operand.isNullLiteral && order(bytes, operand) == .orderedSame
        case .notEqual:
            return operand.isNullLiteral || order(bytes, operand) != .orderedSame
        case .contains:
            return TabularTextMatching.contains(bytes, operand.needle, caseSensitive: caseSensitive)
        case .notContains:
            return !TabularTextMatching.contains(bytes, operand.needle, caseSensitive: caseSensitive)
        case .startsWith:
            return TabularTextMatching.hasPrefix(bytes, operand.needle, caseSensitive: caseSensitive)
        case .endsWith:
            return TabularTextMatching.hasSuffix(bytes, operand.needle, caseSensitive: caseSensitive)
        case .greaterThan:
            return !operand.isNullLiteral && order(bytes, operand) == .orderedDescending
        case .greaterOrEqual:
            return !operand.isNullLiteral && order(bytes, operand) != .orderedAscending
        case .lessThan:
            return !operand.isNullLiteral && order(bytes, operand) == .orderedAscending
        case .lessOrEqual:
            return !operand.isNullLiteral && order(bytes, operand) != .orderedDescending
        case .isNull:
            return false
        case .isNotNull:
            return true
        case .isEmpty:
            return bytes.isEmpty
        case .isNotEmpty:
            return !bytes.isEmpty
        case .inList:
            return listOperands.contains { !$0.isNullLiteral && order(bytes, $0) == .orderedSame }
        case .notInList:
            let values = listOperands.filter { !$0.isNullLiteral }
            return !values.isEmpty && !values.contains { order(bytes, $0) == .orderedSame }
        case .between:
            return order(bytes, operand) != .orderedAscending && order(bytes, secondOperand) != .orderedDescending
        case .regex:
            guard let regex else { return false }
            let text = TabularTextMatching.string(bytes) as NSString
            return regex.firstMatch(in: text as String, options: [], range: NSRange(location: 0, length: text.length)) != nil
        }
    }

    private var prefersNumbers: Bool {
        switch valueKind {
        case .numeric:
            return true
        case .boolean:
            return false
        case .text:
            return comparison.isOrdering
        }
    }

    private var prefersBooleans: Bool {
        valueKind != .text
    }

    private func order(_ bytes: UnsafeBufferPointer<UInt8>, _ operand: Operand) -> ComparisonResult {
        if prefersNumbers, let right = operand.number, let left = TabularValueGrammar.number(bytes) {
            return Self.compare(left, right)
        }
        if prefersBooleans, let right = operand.boolean, let left = TabularValueGrammar.boolean(bytes) {
            return Self.compare(left ? 1 : 0, right ? 1 : 0)
        }
        return TabularTextMatching.compare(bytes, operand.needle, caseSensitive: caseSensitive)
    }

    private static func compare<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

import Foundation

public enum TabularComparison: String, CaseIterable, Sendable, Equatable {
    case equal
    case notEqual
    case contains
    case notContains
    case startsWith
    case endsWith
    case greaterThan
    case greaterOrEqual
    case lessThan
    case lessOrEqual
    case isNull
    case isNotNull
    case isEmpty
    case isNotEmpty
    case inList
    case notInList
    case between
    case regex

    public var isOrdering: Bool {
        switch self {
        case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .between:
            return true
        case .equal, .notEqual, .contains, .notContains, .startsWith, .endsWith, .isNull, .isNotNull,
             .isEmpty, .isNotEmpty, .inList, .notInList, .regex:
            return false
        }
    }
}

public enum TabularValueKind: Sendable, Equatable {
    case text
    case numeric
    case boolean
}

public struct TabularOperand: Sendable, Equatable {
    public var text: String
    public var number: Double?
    public var boolean: Bool?
    public var isNullLiteral: Bool

    public init(text: String, number: Double? = nil, boolean: Bool? = nil, isNullLiteral: Bool = false) {
        self.text = text
        self.number = number
        self.boolean = boolean
        self.isNullLiteral = isNullLiteral
    }
}

public struct TabularCellPredicate: Sendable, Equatable {
    public var column: TabularColumnID
    public var comparison: TabularComparison
    public var valueKind: TabularValueKind
    public var operand: TabularOperand
    public var secondOperand: TabularOperand
    public var listOperands: [TabularOperand]
    public var isCaseSensitive: Bool

    public init(
        column: TabularColumnID,
        comparison: TabularComparison,
        valueKind: TabularValueKind,
        operand: TabularOperand,
        secondOperand: TabularOperand = TabularOperand(text: ""),
        listOperands: [TabularOperand] = [],
        isCaseSensitive: Bool
    ) {
        self.column = column
        self.comparison = comparison
        self.valueKind = valueKind
        self.operand = operand
        self.secondOperand = secondOperand
        self.listOperands = listOperands
        self.isCaseSensitive = isCaseSensitive
    }
}

public struct TabularSearch: Sendable, Equatable {
    public var text: String
    public var columns: [TabularColumnID]

    public init(text: String, columns: [TabularColumnID]) {
        self.text = text
        self.columns = columns
    }
}

public indirect enum TabularRowPredicate: Sendable, Equatable {
    case always
    case cell(TabularCellPredicate)
    case all([TabularRowPredicate])
    case any([TabularRowPredicate])
    case search(TabularSearch)

    public var referencedColumns: [TabularColumnID] {
        var seen = Set<TabularColumnID>()
        var ordered: [TabularColumnID] = []
        collectColumns(into: &ordered, seen: &seen)
        return ordered
    }

    public var isTrivial: Bool {
        switch self {
        case .always:
            return true
        case .all(let parts):
            return parts.allSatisfy(\.isTrivial)
        case .cell, .any, .search:
            return false
        }
    }

    private func collectColumns(into ordered: inout [TabularColumnID], seen: inout Set<TabularColumnID>) {
        switch self {
        case .always:
            return
        case .cell(let predicate):
            if seen.insert(predicate.column).inserted {
                ordered.append(predicate.column)
            }
        case .all(let parts), .any(let parts):
            for part in parts {
                part.collectColumns(into: &ordered, seen: &seen)
            }
        case .search(let search):
            for column in search.columns where seen.insert(column).inserted {
                ordered.append(column)
            }
        }
    }
}

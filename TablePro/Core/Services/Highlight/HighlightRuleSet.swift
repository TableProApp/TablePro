//
//  HighlightRuleSet.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct HighlightRuleSet {
    struct Key: Equatable {
        let rules: [HighlightRule]
        let columns: [String]
        let columnTypes: [ColumnType]
    }

    private struct CompiledRule {
        let rule: HighlightRule
        let column: Int
        let condition: HighlightCondition
    }

    let key: Key
    let unresolvedRuleIDs: Set<UUID>
    private let rowRules: [CompiledRule]
    private let cellRules: [CompiledRule]

    static let empty = HighlightRuleSet(rules: [], columns: [], columnTypes: [])

    init(rules: [HighlightRule], columns: [String], columnTypes: [ColumnType]) {
        key = Key(rules: rules, columns: columns, columnTypes: columnTypes)

        var rowRules: [CompiledRule] = []
        var cellRules: [CompiledRule] = []
        var unresolved = Set<UUID>()
        for rule in rules where rule.isEnabled && rule.isValid {
            guard let column = Self.columnIndex(
                named: rule.columnName,
                occurrence: rule.columnOccurrence,
                in: columns
            ) else {
                unresolved.insert(rule.id)
                continue
            }
            let columnType = column < columnTypes.count ? columnTypes[column] : nil
            let compiled = CompiledRule(
                rule: rule,
                column: column,
                condition: HighlightCondition(rule: rule, columnType: columnType)
            )
            switch rule.target {
            case .row:
                rowRules.append(compiled)
            case .cell:
                cellRules.append(compiled)
            }
        }
        self.rowRules = rowRules
        self.cellRules = cellRules
        self.unresolvedRuleIDs = unresolved
    }

    var isEmpty: Bool { rowRules.isEmpty && cellRules.isEmpty }

    func highlight(for values: ContiguousArray<PluginCellValue>) -> RowHighlight {
        guard !isEmpty else { return .none }
        let rowRule = rowRules.first { Self.matches($0, in: values) }?.rule
        var matchedCells: [Int: HighlightRule] = [:]
        for compiled in cellRules where matchedCells[compiled.column] == nil && Self.matches(compiled, in: values) {
            matchedCells[compiled.column] = compiled.rule
        }
        return RowHighlight(rowRule: rowRule, cellRules: matchedCells)
    }

    static func columnIndex(named name: String, occurrence: Int, in columns: [String]) -> Int? {
        var seen = 0
        for (index, column) in columns.enumerated() where column == name {
            if seen == occurrence { return index }
            seen += 1
        }
        return nil
    }

    static func occurrence(ofColumnAt index: Int, in columns: [String]) -> Int {
        guard index >= 0, index < columns.count else { return 0 }
        let name = columns[index]
        return columns[..<index].reduce(0) { $1 == name ? $0 + 1 : $0 }
    }

    private static func matches(_ compiled: CompiledRule, in values: ContiguousArray<PluginCellValue>) -> Bool {
        guard compiled.column < values.count else { return false }
        return compiled.condition.matches(values[compiled.column])
    }
}

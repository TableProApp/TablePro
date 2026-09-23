//
//  CellFilterMenuBuilder.swift
//  TablePro
//

import AppKit
import TableProPluginKit

@MainActor
enum CellFilterMenuBuilder {
    static let maxValueLength = 10_000

    /// The conditions a cell can offer, each one matching the row it came from.
    ///
    /// The value goes into the same filter a reader could type, so it is offered only where that
    /// filter matches it exactly. The SQL generators trim a value and read the word `NULL` as SQL
    /// NULL outside text columns, a column whose type is unresolved has its literals guessed at,
    /// and some types have no `=` at all, so any of those gets nothing rather than a filter that
    /// would drop the row the reader clicked.
    static func conditions(
        columnName: String,
        columnType: ColumnType?,
        value: PluginCellValue
    ) -> [TableFilter] {
        switch value {
        case .null:
            return [.isNull, .isNotNull].map { filter(columnName, $0) }
        case .text(let text) where text.isEmpty:
            guard let columnType, ColumnTypeSQLQuoting.supportsEmptyStringComparison(columnType) else { return [] }
            return [.isEmpty, .isNotEmpty].map { filter(columnName, $0) }
        case .text(let text):
            guard let columnType, matchesExactly(text, columnType: columnType) else { return [] }
            return comparisonOperators(for: columnType).map { filter(columnName, $0, value: text) }
        case .bytes:
            return []
        }
    }

    static func title(for filter: TableFilter) -> String {
        HighlightRuleDescription.condition(
            columnName: filter.columnName,
            filterOperator: filter.filterOperator,
            value: filter.value,
            secondValue: filter.secondValue,
            valueLimit: HighlightRuleDescription.menuValueLimit
        )
    }

    static func menuItem(
        columnName: String,
        columnType: ColumnType?,
        value: PluginCellValue,
        apply: @escaping (TableFilter) -> Void
    ) -> NSMenuItem? {
        let filters = conditions(columnName: columnName, columnType: columnType, value: value)
        guard !filters.isEmpty else { return nil }

        let submenu = NSMenu()
        for filter in filters {
            submenu.addItem(ClosureMenuTarget.item(title: title(for: filter)) { apply(filter) })
        }

        let item = NSMenuItem(title: String(localized: "Filter"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    private static func matchesExactly(_ text: String, columnType: ColumnType) -> Bool {
        guard ColumnTypeSQLQuoting.hasEqualityOperator(columnType),
              (text as NSString).length <= maxValueLength,
              text == text.trimmingCharacters(in: .whitespaces) else { return false }
        return !HighlightCondition.readsAsNullLiteral(text, columnType: columnType)
    }

    private static func comparisonOperators(for columnType: ColumnType) -> [FilterOperator] {
        switch columnType {
        case .integer, .decimal, .date, .timestamp, .datetime:
            return [.equal, .notEqual, .greaterThan, .lessThan]
        case .text, .boolean, .enumType, .set, .blob, .json, .spatial, .array:
            return [.equal, .notEqual]
        }
    }

    private static func filter(_ columnName: String, _ filterOperator: FilterOperator, value: String = "") -> TableFilter {
        TableFilter(columnName: columnName, filterOperator: filterOperator, value: value)
    }
}

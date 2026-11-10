//
//  TableFilter.swift
//  TablePro
//
//  Model for table data filtering
//

import Foundation
import TableProPluginKit

/// Represents a filter operator for WHERE clause generation
enum FilterOperator: String, CaseIterable, Identifiable, Codable {
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

    var id: String { rawValue }

    /// Whether this operator requires a value input
    var requiresValue: Bool {
        switch self {
        case .isNull, .isNotNull, .isEmpty, .isNotEmpty:
            return false
        default:
            return true
        }
    }

    /// Whether this operator requires two values (for BETWEEN)
    var requiresSecondValue: Bool {
        self == .between
    }

    /// Whether matching for this operator has a case dimension the user can control
    var supportsCaseSensitivity: Bool {
        switch self {
        case .contains, .notContains, .startsWith, .endsWith,
             .equal, .notEqual, .inList, .notInList, .regex:
            return true
        default:
            return false
        }
    }

    /// Pattern matching ignores case by default; exact, list and regex matching does not
    var defaultIsCaseSensitive: Bool {
        switch self {
        case .contains, .notContains, .startsWith, .endsWith:
            return false
        default:
            return true
        }
    }

    /// Display name for UI
    var displayName: String {
        switch self {
        case .equal: return String(localized: "equals")
        case .notEqual: return String(localized: "not equals")
        case .contains: return String(localized: "contains")
        case .notContains: return String(localized: "not contains")
        case .startsWith: return String(localized: "starts with")
        case .endsWith: return String(localized: "ends with")
        case .greaterThan: return String(localized: "greater than")
        case .greaterOrEqual: return String(localized: "greater or equal")
        case .lessThan: return String(localized: "less than")
        case .lessOrEqual: return String(localized: "less or equal")
        case .isNull: return String(localized: "is NULL")
        case .isNotNull: return String(localized: "is not NULL")
        case .isEmpty: return String(localized: "is empty")
        case .isNotEmpty: return String(localized: "is not empty")
        case .inList: return String(localized: "in list")
        case .notInList: return String(localized: "not in list")
        case .between: return String(localized: "between")
        case .regex: return String(localized: "matches regex")
        }
    }

    /// SQL operator symbol for visual recognition in menus
    var symbol: String {
        switch self {
        case .equal: return "="
        case .notEqual: return "!="
        case .greaterThan: return ">"
        case .greaterOrEqual: return ">="
        case .lessThan: return "<"
        case .lessOrEqual: return "<="
        case .contains: return "LIKE %..%"
        case .notContains: return "NOT LIKE %..%"
        case .startsWith: return "LIKE ..%"
        case .endsWith: return "LIKE %.."
        case .inList: return "IN (..)"
        case .notInList: return "NOT IN (..)"
        case .between: return "BETWEEN"
        case .regex: return "~"
        case .isNull, .isNotNull, .isEmpty, .isNotEmpty: return ""
        }
    }
}

/// Represents a single table filter condition
struct TableFilter: Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    var columnName: String
    var filterOperator: FilterOperator
    /// The one text the row holds: the operand of a column condition, or the whole condition of a
    /// raw row. Switching the row between the two keeps it, so what the reader typed never hides
    /// behind the other mode.
    var value: String
    var secondValue: String?
    var isEnabled: Bool
    var isCaseSensitive: Bool

    /// Whether the row holds a condition in the engine's own language rather than a comparison on
    /// `columnName`. Stored, never read from the column name: a table can have a real column named
    /// `__RAW__`, and a filter built from that name and a cell's text has to stay a comparison, or
    /// the cell's text would run as SQL. A raw row is made by `rawCondition(_:)` or
    /// `selectingRawCondition()` only.
    private(set) var isRawSQL: Bool

    /// The array ancestor of `columnName` whose element this condition binds to, for a document
    /// store where several conditions can be required to match the *same* array element. Empty
    /// leaves the condition independent, so any element may satisfy it.
    var elementScope: String?

    /// Special column name for raw SQL mode
    static let rawSQLColumn = "__RAW__"

    init(
        id: UUID = UUID(),
        columnName: String = "",
        filterOperator: FilterOperator = .equal,
        value: String = "",
        secondValue: String? = nil,
        isEnabled: Bool = true,
        isCaseSensitive: Bool? = nil,
        elementScope: String? = nil
    ) {
        self.id = id
        self.columnName = columnName
        self.filterOperator = filterOperator
        self.value = value
        self.secondValue = secondValue
        self.isEnabled = isEnabled
        self.isCaseSensitive = isCaseSensitive ?? filterOperator.defaultIsCaseSensitive
        self.elementScope = elementScope
        self.isRawSQL = false
    }

    /// A row holding the reader's own condition, which runs as written.
    static func rawCondition(
        _ condition: String,
        id: UUID = UUID(),
        filterOperator: FilterOperator = .equal,
        isEnabled: Bool = true
    ) -> TableFilter {
        var filter = TableFilter(
            id: id,
            columnName: rawSQLColumn,
            filterOperator: filterOperator,
            value: condition,
            isEnabled: isEnabled
        )
        filter.isRawSQL = true
        return filter
    }

    /// `rawSQL` is where 0.84 and earlier kept a raw row's text, apart from `value`. `isRawCondition`
    /// is new, so a row from 0.84 is raw by its column name, the only mark that version wrote.
    enum CodingKeys: String, CodingKey {
        case id, columnName, filterOperator, value, secondValue, isEnabled, rawSQL, isCaseSensitive
        case elementScope, isRawCondition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedOperator = try container.decodeIfPresent(FilterOperator.self, forKey: .filterOperator) ?? .equal
        let columnName = try container.decodeIfPresent(String.self, forKey: .columnName) ?? ""
        let value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        let isRaw = try container.decodeIfPresent(Bool.self, forKey: .isRawCondition)
            ?? (columnName == Self.rawSQLColumn)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.columnName = columnName
        self.filterOperator = decodedOperator
        self.isRawSQL = isRaw
        // A raw row of 0.84 with no `rawSQL` was switched there and never typed into: its `value`
        // belonged to the column it left, and read as a condition it could match every row.
        if isRaw {
            self.value = try container.decodeIfPresent(String.self, forKey: .rawSQL) ?? ""
        } else {
            self.value = value
        }
        self.secondValue = try container.decodeIfPresent(String.self, forKey: .secondValue)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.isCaseSensitive = try container.decodeIfPresent(Bool.self, forKey: .isCaseSensitive)
            ?? decodedOperator.defaultIsCaseSensitive
        self.elementScope = try container.decodeIfPresent(String.self, forKey: .elementScope)
    }

    /// A raw row also writes its text under `rawSQL`, because the previous stable reads a raw
    /// row's text only from there and would load the row empty and drop it.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(columnName, forKey: .columnName)
        try container.encode(filterOperator, forKey: .filterOperator)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(secondValue, forKey: .secondValue)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isRawSQL, forKey: .isRawCondition)
        if isRawSQL {
            try container.encode(value, forKey: .rawSQL)
        }
        try container.encode(isCaseSensitive, forKey: .isCaseSensitive)
        try container.encodeIfPresent(elementScope, forKey: .elementScope)
    }

    /// Whether this filter is valid (has enough info to apply)
    var isValid: Bool {
        if isRawSQL {
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !columnName.isEmpty else { return false }
        guard filterOperator.requiresValue else { return true }
        if filterOperator == .inList || filterOperator == .notInList {
            return !FilterOperand.listItems(value).isEmpty
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard filterOperator.requiresSecondValue else { return true }
        return !(secondValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Validation error message (nil if valid)
    var validationError: String? {
        if isRawSQL {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(localized: "Raw SQL cannot be empty")
            }
            return nil
        }

        if columnName.isEmpty {
            return String(localized: "Please select a column")
        }

        if filterOperator.requiresValue {
            if value.isEmpty {
                return String(localized: "Value is required")
            }
            if filterOperator.requiresSecondValue && (secondValue?.isEmpty ?? true) {
                return String(localized: "Second value is required for BETWEEN")
            }
        }

        return nil
    }
}

extension TableFilter {
    /// Whether both rows select the same rows, whatever their id, position or enabled flag.
    ///
    /// Only what the row's kind and operator read takes part. A field the row keeps for a switch
    /// back, such as the upper bound after leaving BETWEEN, selects nothing, so it cannot make two
    /// identical conditions look different.
    func hasSameCondition(as other: TableFilter) -> Bool {
        guard isRawSQL == other.isRawSQL, columnName == other.columnName else { return false }
        if isRawSQL { return value == other.value }
        guard filterOperator == other.filterOperator, elementScope == other.elementScope else { return false }
        if filterOperator.requiresValue, value != other.value { return false }
        if filterOperator.requiresSecondValue, (secondValue ?? "") != (other.secondValue ?? "") { return false }
        if filterOperator.supportsCaseSensitivity, isCaseSensitive != other.isCaseSensitive { return false }
        return true
    }

    /// The row as a comparison on `name`, from a raw condition or another column. The text stays as
    /// typed. A scope names an array of the old column, so it cannot carry over.
    func selectingColumn(_ name: String) -> TableFilter {
        guard isRawSQL || name != columnName else { return self }
        var updated = self
        updated.columnName = name
        updated.isRawSQL = false
        updated.elementScope = nil
        return updated
    }

    /// The row as the reader's own condition, with the text it holds as that condition.
    func selectingRawCondition() -> TableFilter {
        guard !isRawSQL else { return self }
        var updated = self
        updated.columnName = Self.rawSQLColumn
        updated.isRawSQL = true
        updated.elementScope = nil
        return updated
    }

    /// A comparison on a real column that shares the raw row's name. A driver reads that column name
    /// as a raw condition and would run the value as one, so such a row never reaches a driver.
    var namesRawConditionColumn: Bool {
        !isRawSQL && columnName == Self.rawSQLColumn
    }

    /// Match Case returns to the new operator's usual setting, so a pattern row ignores case
    /// unless the reader turns it on for that operator.
    func selectingOperator(_ newOperator: FilterOperator) -> TableFilter {
        guard newOperator != filterOperator else { return self }
        var updated = self
        updated.filterOperator = newOperator
        updated.isCaseSensitive = newOperator.defaultIsCaseSensitive
        return updated
    }

    /// The same row under a new identity, every field it holds carried over.
    func duplicated() -> TableFilter {
        var copy = TableFilter(
            columnName: columnName,
            filterOperator: filterOperator,
            value: value,
            secondValue: secondValue,
            isEnabled: isEnabled,
            isCaseSensitive: isCaseSensitive,
            elementScope: elementScope
        )
        copy.isRawSQL = isRawSQL
        return copy
    }

    /// The joined `value` stays as it was for drivers that still read a `BETWEEN` as one
    /// comma-separated string; `secondValue` carries the upper bound intact for those that don't,
    /// so a bound holding a comma is no longer mistaken for the separator.
    var asPluginQueryFilter: PluginQueryFilter {
        if isRawSQL {
            return PluginQueryFilter(
                column: columnName,
                op: filterOperator.rawValue,
                value: value,
                secondValue: nil,
                elementScope: nil
            )
        }
        let resolvedValue: String
        if filterOperator == .between, let second = secondValue {
            resolvedValue = "\(value),\(second)"
        } else {
            resolvedValue = value
        }
        return PluginQueryFilter(
            column: columnName,
            op: filterOperator.rawValue,
            value: resolvedValue,
            isCaseSensitive: isCaseSensitive,
            secondValue: filterOperator == .between ? secondValue : nil,
            elementScope: elementScope
        )
    }
}

/// Stores per-tab filter state (preserves filters when switching tabs)
struct TabFilterState: Equatable, Hashable, Codable {
    var filters: [TableFilter]
    var commit: FilterCommit?
    var isVisible: Bool
    var filterLogicMode: FilterLogicMode
    var keyPattern: String
    var keyTypeScope: String?

    /// The filters the rows on screen were actually fetched with.
    ///
    /// `filters` is the panel's editable draft, and `appliedFilters` resolves from it, so both
    /// describe a query that has not run the moment a reader types into a filter row without
    /// pressing Apply. Anything asking what a tab is *showing*, rather than what its panel says,
    /// has to read this. It is written wherever a query is built from the filters and is
    /// deliberately not persisted: a restored tab rebuilds its query on first load, which fills it.
    var executedFilters: [TableFilter] = []

    /// How `executedFilters` were joined, written beside them. Nil until the tab runs its first
    /// filtered query, so a tab that restored filters and has not loaded yet reruns those.
    var executedLogicMode: FilterLogicMode?

    /// Whether the panel edits builder rows or one typed condition. Only a panel that also holds the
    /// sort offers the switch (`DataGridSettings.showsSortInFilterPanel`); every other panel reads
    /// `effectiveEditMode`, which falls back to the rows.
    var editMode: FilterEditMode = .builder

    /// The builder rows Text mode replaced, so switching back before typing anything returns them.
    /// Deliberately not persisted: a restored tab has no rows to return to.
    var textModeOrigin: FilterTextModeOrigin?

    /// The Sort By section's edits, nil while it shows the tab's sort as it is. A header click
    /// sorts at once and clears it, so the section follows the header. Not persisted: the sort the
    /// rows were fetched with is the tab's `SortState`, and a draft is only what Apply would run.
    var sortDraft: [FilterSortCriterion]?

    init(isVisible: Bool = false) {
        self.filters = []
        self.commit = nil
        self.isVisible = isVisible
        self.filterLogicMode = .and
        self.keyPattern = ""
        self.keyTypeScope = nil
    }

    enum CodingKeys: String, CodingKey {
        case filters, commit, isVisible, filterLogicMode, keyPattern, keyTypeScope, editMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.filters = try container.decodeIfPresent([TableFilter].self, forKey: .filters) ?? []
        self.commit = try container.decodeIfPresent(FilterCommit.self, forKey: .commit)
        self.isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
        self.filterLogicMode = try container.decodeIfPresent(FilterLogicMode.self, forKey: .filterLogicMode) ?? .and
        self.keyPattern = try container.decodeIfPresent(String.self, forKey: .keyPattern) ?? ""
        self.keyTypeScope = try container.decodeIfPresent(String.self, forKey: .keyTypeScope)
        self.editMode = (try? container.decodeIfPresent(FilterEditMode.self, forKey: .editMode)) ?? .builder
    }

    var appliedFilters: [TableFilter] {
        guard let commit else { return [] }
        return Self.resolve(commit, in: filters)
    }

    /// What a page turn, sort, refresh or count runs again: the filters the rows on screen were
    /// fetched with, never the panel's draft. A row edited after Apply, or switched between a raw
    /// condition and a column with its text kept, runs only once Apply runs it.
    var rerunFilters: (filters: [TableFilter], logicMode: FilterLogicMode) {
        guard commit != nil else { return ([], filterLogicMode) }
        guard let executedLogicMode else { return (appliedFilters, filterLogicMode) }
        return (executedFilters, executedLogicMode)
    }

    /// Records the draft's applied filters as the ones running, for a host that has just run them.
    mutating func adoptAppliedFiltersAsRunning() {
        executedFilters = appliedFilters
        executedLogicMode = commit == nil ? nil : filterLogicMode
    }

    /// What a table's saved filters hold: every valid row with its own enabled flag, the logic mode,
    /// and whether those rows were running.
    ///
    /// Never `appliedFilters`, which is the query's reading of the same rows: `.all` drops unchecked
    /// rows and `.solo` keeps one row forced on, so saving that loses rows the reader only switched off.
    ///
    /// Rows the reader typed but never applied are saved too, with `isApplied` false, so reopening
    /// the table brings them back without running them. An empty row list still saves nothing, which
    /// the storage reads as a delete: that is Remove All Filters, the gesture that destroys the
    /// table's saved state. Under `FilterRestoreBehavior.dontSave` nothing is written at all, in
    /// either direction, so what is already on disk survives both a save and a delete.
    var persistedState: PersistedFilterState {
        PersistedFilterState(
            filters: filters.filter(\.isValid),
            logicMode: filterLogicMode,
            isApplied: commit != nil,
            editMode: effectiveEditMode
        )
    }

    static func resolve(_ commit: FilterCommit, in filters: [TableFilter]) -> [TableFilter] {
        switch commit {
        case .all:
            return filters.filter { $0.isEnabled && $0.isValid }
        case .solo(let id):
            guard var match = filters.first(where: { $0.id == id }), match.isValid else { return [] }
            match.isEnabled = true
            return [match]
        }
    }

    var hasAppliedFilters: Bool {
        !appliedFilters.isEmpty
    }

    var allEnabledState: Bool? {
        guard !filters.isEmpty else { return false }
        if filters.allSatisfy({ $0.isEnabled }) { return true }
        if filters.allSatisfy({ !$0.isEnabled }) { return false }
        return nil
    }
}

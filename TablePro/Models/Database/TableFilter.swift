//
//  TableFilter.swift
//  TablePro
//
//  Model for table data filtering
//

import Foundation

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
}

/// Represents a single table filter condition
struct TableFilter: Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    var columnName: String          // Column to filter on, or "__RAW__" for raw SQL
    var filterOperator: FilterOperator
    var value: String
    var secondValue: String?        // For BETWEEN operator
    var isSelected: Bool            // For multi-select apply
    var isEnabled: Bool             // Whether filter is active
    var rawSQL: String?             // For raw SQL mode

    /// Special column name for raw SQL mode
    static let rawSQLColumn = "__RAW__"

    init(
        id: UUID = UUID(),
        columnName: String = "",
        filterOperator: FilterOperator = .equal,
        value: String = "",
        secondValue: String? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        rawSQL: String? = nil
    ) {
        self.id = id
        self.columnName = columnName
        self.filterOperator = filterOperator
        self.value = value
        self.secondValue = secondValue
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.rawSQL = rawSQL
    }

    /// Whether this filter is valid (has enough info to apply)
    var isValid: Bool {
        if columnName == Self.rawSQLColumn {
            return rawSQL?.isEmpty == false
        }
        guard !columnName.isEmpty else { return false }
        if filterOperator.requiresValue {
            if filterOperator.requiresSecondValue {
                return !value.isEmpty && !(secondValue?.isEmpty ?? true)
            }
            return !value.isEmpty
        }
        return true
    }

    /// Whether this is a raw SQL filter
    var isRawSQL: Bool {
        columnName == Self.rawSQLColumn
    }

    /// Validation error message (nil if valid)
    var validationError: String? {
        if columnName == Self.rawSQLColumn {
            if rawSQL?.isEmpty ?? true {
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

/// Stores per-tab filter state (preserves filters when switching tabs)
struct TabFilterState: Equatable, Hashable, Codable {
    var filters: [TableFilter]
    var appliedFilters: [TableFilter]
    var isVisible: Bool
    var filterLogicMode: FilterLogicMode

    init() {
        self.filters = []
        self.appliedFilters = []
        self.isVisible = false
        self.filterLogicMode = .and
    }

    var hasChanges: Bool {
        !filters.isEmpty || !appliedFilters.isEmpty
    }

    var hasAppliedFilters: Bool {
        !appliedFilters.isEmpty
    }
}

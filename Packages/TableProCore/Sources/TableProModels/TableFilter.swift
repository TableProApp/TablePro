import Foundation

public struct TableFilter: Identifiable, Codable, Sendable {
    public var id: UUID
    public var columnName: String
    public var filterOperator: FilterOperator
    public var value: String
    public var secondValue: String
    public var isEnabled: Bool
    public var rawSQL: String?
    public var isCaseSensitive: Bool

    public static let rawSQLColumn = "__raw_sql__"

    public var isValid: Bool {
        if columnName == Self.rawSQLColumn {
            guard let sql = rawSQL, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            return true
        }
        guard !columnName.isEmpty else { return false }
        switch filterOperator {
        case .isNull, .isNotNull:
            return true
        case .between:
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !secondValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public init(
        id: UUID = UUID(),
        columnName: String = "",
        filterOperator: FilterOperator = .equal,
        value: String = "",
        secondValue: String = "",
        isEnabled: Bool = true,
        rawSQL: String? = nil,
        isCaseSensitive: Bool? = nil
    ) {
        self.id = id
        self.columnName = columnName
        self.filterOperator = filterOperator
        self.value = value
        self.secondValue = secondValue
        self.isEnabled = isEnabled
        self.rawSQL = rawSQL
        self.isCaseSensitive = isCaseSensitive ?? filterOperator.defaultIsCaseSensitive
    }

    public enum CodingKeys: String, CodingKey {
        case id, columnName, filterOperator, value, secondValue, isEnabled, rawSQL, isCaseSensitive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedOperator = try container.decodeIfPresent(FilterOperator.self, forKey: .filterOperator) ?? .equal
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.columnName = try container.decodeIfPresent(String.self, forKey: .columnName) ?? ""
        self.filterOperator = decodedOperator
        self.value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        self.secondValue = try container.decodeIfPresent(String.self, forKey: .secondValue) ?? ""
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.rawSQL = try container.decodeIfPresent(String.self, forKey: .rawSQL)
        self.isCaseSensitive = try container.decodeIfPresent(Bool.self, forKey: .isCaseSensitive)
            ?? decodedOperator.defaultIsCaseSensitive
    }
}

public enum FilterOperator: String, Codable, Sendable, CaseIterable {
    case equal
    case notEqual
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
    case like
    case notLike
    case isNull
    case isNotNull
    case `in`
    case notIn
    case between
    case contains
    case startsWith
    case endsWith

    public var supportsCaseSensitivity: Bool {
        switch self {
        case .like, .notLike, .contains, .startsWith, .endsWith, .equal, .notEqual, .in, .notIn:
            return true
        default:
            return false
        }
    }

    /// Pattern matching ignores case by default; exact and list matching does not
    public var defaultIsCaseSensitive: Bool {
        switch self {
        case .like, .notLike, .contains, .startsWith, .endsWith:
            return false
        default:
            return true
        }
    }

    public var sqlSymbol: String {
        switch self {
        case .equal: return "="
        case .notEqual: return "!="
        case .greaterThan: return ">"
        case .greaterThanOrEqual: return ">="
        case .lessThan: return "<"
        case .lessThanOrEqual: return "<="
        case .like: return "LIKE"
        case .notLike: return "NOT LIKE"
        case .isNull: return "IS NULL"
        case .isNotNull: return "IS NOT NULL"
        case .in: return "IN"
        case .notIn: return "NOT IN"
        case .between: return "BETWEEN"
        case .contains: return "LIKE"
        case .startsWith: return "LIKE"
        case .endsWith: return "LIKE"
        }
    }
}

public enum FilterLogicMode: String, Codable, Sendable {
    case and = "AND"
    case or = "OR"
}

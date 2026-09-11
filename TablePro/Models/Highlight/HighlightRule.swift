//
//  HighlightRule.swift
//  TablePro
//

import Foundation

enum HighlightColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .red: return String(localized: "Red")
        case .orange: return String(localized: "Orange")
        case .yellow: return String(localized: "Yellow")
        case .green: return String(localized: "Green")
        case .blue: return String(localized: "Blue")
        case .purple: return String(localized: "Purple")
        case .gray: return String(localized: "Gray")
        }
    }
}

enum HighlightTarget: String, CaseIterable, Identifiable, Codable, Sendable {
    case row
    case cell

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .row: return String(localized: "Row")
        case .cell: return String(localized: "Cell")
        }
    }
}

struct HighlightRule: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: UUID
    var isEnabled: Bool
    var columnName: String
    var columnOccurrence: Int
    var filterOperator: FilterOperator
    var value: String
    var secondValue: String?
    var isCaseSensitive: Bool
    var color: HighlightColor
    var target: HighlightTarget

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        columnName: String,
        columnOccurrence: Int = 0,
        filterOperator: FilterOperator = .equal,
        value: String = "",
        secondValue: String? = nil,
        isCaseSensitive: Bool? = nil,
        color: HighlightColor = .yellow,
        target: HighlightTarget = .row
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.columnName = columnName
        self.columnOccurrence = max(0, columnOccurrence)
        self.filterOperator = filterOperator
        self.value = value
        self.secondValue = secondValue
        self.isCaseSensitive = isCaseSensitive ?? filterOperator.defaultIsCaseSensitive
        self.color = color
        self.target = target
    }

    private enum CodingKeys: String, CodingKey {
        case id, isEnabled, columnName, columnOccurrence, filterOperator, value, secondValue
        case isCaseSensitive, color, target
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedOperator = try container.decode(FilterOperator.self, forKey: .filterOperator)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.columnName = try container.decode(String.self, forKey: .columnName)
        self.columnOccurrence = max(0, try container.decodeIfPresent(Int.self, forKey: .columnOccurrence) ?? 0)
        self.filterOperator = decodedOperator
        self.value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        self.secondValue = try container.decodeIfPresent(String.self, forKey: .secondValue)
        self.isCaseSensitive = try container.decodeIfPresent(Bool.self, forKey: .isCaseSensitive)
            ?? decodedOperator.defaultIsCaseSensitive
        self.color = try container.decode(HighlightColor.self, forKey: .color)
        self.target = try container.decodeIfPresent(HighlightTarget.self, forKey: .target) ?? .row
    }

    var isValid: Bool {
        guard !columnName.isEmpty else { return false }
        guard filterOperator.requiresValue else { return true }
        guard !value.isEmpty else { return false }
        guard filterOperator.requiresSecondValue else { return true }
        return !(secondValue?.isEmpty ?? true)
    }

    func hasSameCondition(as other: HighlightRule) -> Bool {
        columnName == other.columnName
            && columnOccurrence == other.columnOccurrence
            && filterOperator == other.filterOperator
            && value == other.value
            && (filterOperator.requiresSecondValue ? secondValue == other.secondValue : true)
            && isCaseSensitive == other.isCaseSensitive
            && target == other.target
    }
}

struct RowHighlight: Equatable, Sendable {
    let rowRule: HighlightRule?
    let cellRules: [Int: HighlightRule]

    static let none = RowHighlight(rowRule: nil, cellRules: [:])

    var isEmpty: Bool { rowRule == nil && cellRules.isEmpty }

    var rowColor: HighlightColor? { rowRule?.color }

    func cellRule(forColumn column: Int) -> HighlightRule? {
        cellRules[column]
    }

    func describingRule(forColumn column: Int) -> HighlightRule? {
        cellRules[column] ?? rowRule
    }
}

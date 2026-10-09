//
//  SelectionSummary.swift
//  TablePro
//

import Foundation
import TableProNumberFormatting

enum SelectionSummaryColumnRule: Sendable, Equatable {
    case numeric
    case numericIfParsable
    case countOnly
}

struct SelectionSummaryColumnPolicy: Sendable, Equatable {
    let rules: [SelectionSummaryColumnRule]
    let emptyTextIsEmpty: Bool
}

struct SelectionSummary: Sendable, Equatable {
    let valueCount: Int
    let emptyCount: Int
    let notANumberCount: Int
    let numbers: ExactNumericSummary?
    let coversWholeColumn: Bool
}

struct SelectionSummaryInput: Sendable {
    let selection: GridSelection
    let tableRows: TableRows
    let displayIDs: [RowID]?
    let dataColumnsByDisplayPosition: [Int]
    let policy: SelectionSummaryColumnPolicy
    let deletedRowIDs: Set<RowID>
    let insertedRowIDs: Set<RowID>
    let modifiedCells: [RowID: Set<Int>]

    init(
        selection: GridSelection,
        tableRows: TableRows,
        displayIDs: [RowID]? = nil,
        dataColumnsByDisplayPosition: [Int],
        policy: SelectionSummaryColumnPolicy,
        deletedRowIDs: Set<RowID> = [],
        insertedRowIDs: Set<RowID> = [],
        modifiedCells: [RowID: Set<Int>] = [:]
    ) {
        self.selection = selection
        self.tableRows = tableRows
        self.displayIDs = displayIDs
        self.dataColumnsByDisplayPosition = dataColumnsByDisplayPosition
        self.policy = policy
        self.deletedRowIDs = deletedRowIDs
        self.insertedRowIDs = insertedRowIDs
        self.modifiedCells = modifiedCells
    }
}

internal extension SelectionSummaryColumnPolicy {
    func rule(forColumn column: Int) -> SelectionSummaryColumnRule {
        rules.indices.contains(column) ? rules[column] : .countOnly
    }

    /// A display format replaces the text the reader sees, so a number shown as a date is counted
    /// and never summed.
    static func derived(
        columnTypes: [ColumnType],
        displayFormats: [ValueDisplayFormat?],
        columnCount: Int
    ) -> SelectionSummaryColumnPolicy {
        let rules = (0..<max(0, columnCount)).map { column -> SelectionSummaryColumnRule in
            if displayFormats.indices.contains(column), let format = displayFormats[column], format != .raw {
                return .countOnly
            }
            guard columnTypes.indices.contains(column) else { return .numericIfParsable }
            return rule(for: columnTypes[column])
        }
        return SelectionSummaryColumnPolicy(rules: rules, emptyTextIsEmpty: false)
    }

    /// A typed text column holds identifiers like ZIP codes, so only a column the driver could not
    /// type is read as a number when its text parses as one.
    static func rule(for columnType: ColumnType) -> SelectionSummaryColumnRule {
        switch columnType {
        case .integer, .decimal:
            return .numeric
        case .text(let rawType):
            guard let rawType, !rawType.isEmpty else { return .numericIfParsable }
            return .countOnly
        case .date, .timestamp, .datetime, .boolean, .blob, .json, .enumType, .set, .spatial, .array:
            return .countOnly
        }
    }
}

//
//  GridSelectionOwner.swift
//  TablePro
//

import Foundation

// Which grid's model holds the selection the inspector, the Edit menu and the status bar read.
internal enum GridSelectionOwner: Equatable {
    case dataGrid
    case schemaGrid
    case none

    // An exhaustive switch over the mode, so a mode added later has to say whose selection it shows.
    static func resolve(tabType: TabType?, resultsViewMode: ResultsViewMode?) -> GridSelectionOwner {
        guard let tabType else { return .none }
        if tabType == .createTable { return .schemaGrid }

        if let resultsViewMode {
            switch resultsViewMode {
            case .structure:
                return .schemaGrid
            case .chart, .output:
                // Nothing in a chart or in printed output selects a row.
                return .none
            case .data, .json, .map:
                break
            }
        }

        switch tabType {
        case .table, .query:
            // Map selects through the same model: a clicked shape selects its row.
            return .dataGrid
        case .createTable, .erDiagram, .serverDashboard, .usersRoles, .insights, .tableHealth, .objectSource,
             .versionHistory, .tableListing, .routineDebug:
            return .none
        }
    }
}

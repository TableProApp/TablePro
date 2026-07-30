//
//  GridSelectionOwner.swift
//  TablePro
//
//  Resolves which grid owns the row selection in `GridSelectionState`. The data grid,
//  the structure grid, and the new-table grid all publish into that one channel, so
//  every consumer has to agree on whose display positions the indices are.
//

import Foundation

internal enum GridSelectionOwner: Equatable {
    case dataGrid
    case schemaGrid
    case none

    static func resolve(tabType: TabType?, resultsViewMode: ResultsViewMode?) -> GridSelectionOwner {
        guard let tabType else { return .none }
        if tabType == .createTable { return .schemaGrid }
        if resultsViewMode == .structure { return .schemaGrid }
        switch tabType {
        case .table, .query:
            return .dataGrid
        case .createTable, .erDiagram, .serverDashboard, .usersRoles:
            return .none
        }
    }
}

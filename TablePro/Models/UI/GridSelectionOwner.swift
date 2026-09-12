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

    /// The mode arm is an exhaustive switch rather than an exception list, so a mode added later
    /// cannot compile without saying whose display positions its selection is. It used to name
    /// `.chart` alone in an if-chain, which meant any new mode fell through to the `tabType`
    /// switch below and silently claimed the data grid's channel.
    static func resolve(tabType: TabType?, resultsViewMode: ResultsViewMode?) -> GridSelectionOwner {
        guard let tabType else { return .none }
        if tabType == .createTable { return .schemaGrid }

        if let resultsViewMode {
            switch resultsViewMode {
            case .structure:
                return .schemaGrid
            case .chart:
                /// Nothing in a chart selects a row, so the indices left over from the grid are
                /// nobody's.
                return .none
            case .data, .json, .map:
                break
            }
        }

        switch tabType {
        case .table, .query:
            /// Map writes into this channel itself: clicking a shape selects that row, and the
            /// indices it writes are the data grid's display positions, resolved through
            /// `DisplayRowMapping`.
            return .dataGrid
        case .createTable, .erDiagram, .serverDashboard, .usersRoles, .insights, .objectSource:
            return .none
        }
    }
}

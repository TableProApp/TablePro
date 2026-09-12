//
//  ResultsModeAvailability.swift
//  TablePro
//

import Foundation

/// Which result modes a tab can offer.
///
/// Pure so the switcher's segment set is decided once and asserted in tests, rather than duplicated
/// as two hand-written pickers that drifted apart and each carried its own hardcoded width.
enum ResultsModeAvailability {
    /// Map is the only mode gated on what the result holds rather than on what kind of tab it is.
    ///
    /// Chart is offered whenever there are columns and explains itself inside the view when none of
    /// them is numeric, which is the cheaper shape. Map does not follow it, because a geometry
    /// column is rare: a Map segment on every result in the app would be permanent chrome for a
    /// pane that almost never has anything to draw.
    static func modes(
        tabType: TabType?,
        hasTableName: Bool,
        hasColumns: Bool,
        hasSpatialColumn: Bool = false
    ) -> [ResultsViewMode] {
        guard let tabType else { return [] }
        if tabType == .table, hasTableName {
            return [.data, .structure, .json, .chart] + (hasSpatialColumn ? [.map] : [])
        }
        guard hasColumns else { return [] }
        return [.data, .json, .chart] + (hasSpatialColumn ? [.map] : [])
    }

    /// The mode a tab should be on, given what it can currently offer.
    ///
    /// A mode that leaves `availableModes` takes its own switcher segment and all four View menu
    /// items with it, and those items carry no key equivalent, so nothing would be left to press.
    /// That stranded a tab for good when the next statement returned no columns, which a
    /// succeeding non-SELECT does on every run. Reconciling costs nothing when the mode is still
    /// offered, which is the overwhelmingly common case.
    static func reconcile(_ mode: ResultsViewMode, availableModes: [ResultsViewMode]) -> ResultsViewMode {
        guard !availableModes.isEmpty else { return .data }
        return availableModes.contains(mode) ? mode : .data
    }
}

extension ResultsViewMode {
    /// JSON stays untranslated: it names a format, not a part of the interface.
    var displayName: String {
        switch self {
        case .data:
            return String(localized: "Data")
        case .structure:
            return String(localized: "Structure")
        case .json:
            return "JSON"
        case .chart:
            return String(localized: "Chart")
        case .map:
            return String(localized: "Map")
        }
    }
}

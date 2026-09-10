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
    static func modes(tabType: TabType?, hasTableName: Bool, hasColumns: Bool) -> [ResultsViewMode] {
        guard let tabType else { return [] }
        if tabType == .table, hasTableName {
            return [.data, .structure, .json, .chart]
        }
        guard hasColumns else { return [] }
        return [.data, .json, .chart]
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
        }
    }
}

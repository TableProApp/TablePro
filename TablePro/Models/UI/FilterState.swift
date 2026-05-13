//
//  FilterState.swift
//  TablePro
//

import Foundation

enum FilterLogicMode: String, Codable {
    case and = "AND"
    case or = "OR"

    var displayName: String {
        rawValue
    }
}

extension TabFilterState {
    init(filters: [TableFilter], appliedFilters: [TableFilter], isVisible: Bool, filterLogicMode: FilterLogicMode) {
        self.filters = filters
        self.appliedFilters = appliedFilters
        self.isVisible = isVisible
        self.filterLogicMode = filterLogicMode
    }
}

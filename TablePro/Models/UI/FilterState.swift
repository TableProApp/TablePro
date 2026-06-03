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

enum FilterCommit: Codable, Equatable, Hashable {
    case all
    case solo(UUID)
}

extension TabFilterState {
    init(filters: [TableFilter], commit: FilterCommit?, isVisible: Bool, filterLogicMode: FilterLogicMode) {
        self.filters = filters
        self.commit = commit
        self.isVisible = isVisible
        self.filterLogicMode = filterLogicMode
    }
}

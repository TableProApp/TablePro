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

struct BrowseSearchState: Codable, Equatable {
    var pattern: String
    var typeScope: String?

    init(pattern: String = "", typeScope: String? = nil) {
        self.pattern = pattern
        self.typeScope = typeScope
    }

    var isActive: Bool {
        !pattern.trimmingCharacters(in: .whitespaces).isEmpty || typeScope != nil
    }
}

extension TabFilterState {
    init(filters: [TableFilter], commit: FilterCommit?, isVisible: Bool, filterLogicMode: FilterLogicMode) {
        self.filters = filters
        self.commit = commit
        self.isVisible = isVisible
        self.filterLogicMode = filterLogicMode
        self.keyPattern = ""
        self.keyTypeScope = nil
    }

    var browseSearch: BrowseSearchState {
        get { BrowseSearchState(pattern: keyPattern, typeScope: keyTypeScope) }
        set {
            keyPattern = newValue.pattern
            keyTypeScope = newValue.typeScope
        }
    }

    var hasActiveBrowseSearch: Bool {
        browseSearch.isActive
    }
}

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

struct PersistedFilterState: Codable, Equatable {
    var filters: [TableFilter]
    var logicMode: FilterLogicMode

    init(filters: [TableFilter], logicMode: FilterLogicMode = .and) {
        self.filters = filters
        self.logicMode = logicMode
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           let filters = try? keyed.decode([TableFilter].self, forKey: .filters) {
            self.filters = filters
            self.logicMode = (try? keyed.decode(FilterLogicMode.self, forKey: .logicMode)) ?? .and
            return
        }
        let single = try decoder.singleValueContainer()
        self.filters = try single.decode([TableFilter].self)
        self.logicMode = .and
    }

    private enum CodingKeys: String, CodingKey {
        case filters, logicMode
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

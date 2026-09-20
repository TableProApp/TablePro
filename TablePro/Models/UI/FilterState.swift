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
    /// Whether the rows were running against the table when they were saved.
    ///
    /// A plain flag rather than the `FilterCommit` itself, because `persistedState` drops invalid
    /// rows and nothing clears a `.solo` commit whose row became invalid: that id would survive to
    /// disk pointing at a row no longer in the file, and restoring it resolves to nothing applied
    /// while the panel shows rows. An applied set restores as `.all` over the rows that survived,
    /// each keeping its own enabled flag.
    ///
    /// Absent in every file written before this existed, which decodes to `true`: only an applied
    /// set was ever saved.
    var isApplied: Bool

    init(filters: [TableFilter], logicMode: FilterLogicMode = .and, isApplied: Bool = true) {
        self.filters = filters
        self.logicMode = logicMode
        self.isApplied = isApplied
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           let filters = try? keyed.decode([TableFilter].self, forKey: .filters) {
            self.filters = filters
            self.logicMode = (try? keyed.decode(FilterLogicMode.self, forKey: .logicMode)) ?? .and
            self.isApplied = (try? keyed.decode(Bool.self, forKey: .isApplied)) ?? true
            return
        }
        let single = try decoder.singleValueContainer()
        self.filters = try single.decode([TableFilter].self)
        self.logicMode = .and
        self.isApplied = true
    }

    private enum CodingKeys: String, CodingKey {
        case filters, logicMode, isApplied
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

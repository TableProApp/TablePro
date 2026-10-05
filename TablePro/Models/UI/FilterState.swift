//
//  FilterState.swift
//  TablePro
//

import Foundation
import TableProPluginKit

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

    /// The search as the filters a plugin's browse reads: a raw `MATCH` glob on the key and a
    /// `TYPE` scope. The browse query and `Count Exactly` both build from this, so the count is of
    /// the keys the grid lists.
    var pluginQueryFilters: [PluginQueryFilter] {
        var filters: [PluginQueryFilter] = []
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)
        if !trimmedPattern.isEmpty {
            filters.append(PluginQueryFilter(column: "Key", op: "MATCH", value: trimmedPattern))
        }
        if let typeScope, !typeScope.isEmpty {
            filters.append(PluginQueryFilter(column: "Type", op: "=", value: typeScope))
        }
        return filters
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

    /// The search the tab's browse runs, nil when it narrows nothing. Only an engine that declares
    /// a browse search runs one, so the caller says whether this tab's engine does.
    func activeBrowseSearch(isSupported: Bool) -> BrowseSearchState? {
        isSupported && hasActiveBrowseSearch ? browseSearch : nil
    }

    /// Whether the tab lists fewer rows than its table holds, so the table's own size, which is
    /// what an estimate measures, is not the total of what is on screen.
    func narrowsRows(browseSearchIsSupported: Bool) -> Bool {
        hasAppliedFilters || activeBrowseSearch(isSupported: browseSearchIsSupported) != nil
    }
}

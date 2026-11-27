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

// What the grid's rows were fetched with: the one record a page turn, sort, count or share reruns.
struct AppliedFilters: Codable, Equatable, Hashable {
    let filters: [TableFilter]
    let logicMode: FilterLogicMode
    // The draft row applied on its own, whatever its checkbox says.
    let aloneFilterID: UUID?

    init?(filters: [TableFilter], logicMode: FilterLogicMode, aloneFilterID: UUID? = nil) {
        guard !filters.isEmpty else { return nil }
        self.filters = filters
        self.logicMode = logicMode
        self.aloneFilterID = aloneFilterID
    }

    static func checkedRows(of draft: [TableFilter], logicMode: FilterLogicMode) -> AppliedFilters? {
        AppliedFilters(filters: draft.filter { $0.isEnabled && $0.isValid }, logicMode: logicMode)
    }

    static func alone(_ row: TableFilter, logicMode: FilterLogicMode) -> AppliedFilters? {
        guard row.isValid else { return nil }
        var running = row
        running.isEnabled = true
        return AppliedFilters(filters: [running], logicMode: logicMode, aloneFilterID: row.id)
    }

    func removing(_ id: UUID) -> AppliedFilters? {
        guard aloneFilterID != id else { return nil }
        return AppliedFilters(filters: filters.filter { $0.id != id }, logicMode: logicMode, aloneFilterID: aloneFilterID)
    }

    func withLogicMode(_ mode: FilterLogicMode) -> AppliedFilters {
        AppliedFilters(filters: filters, logicMode: mode, aloneFilterID: aloneFilterID) ?? self
    }

    func mapFilters(_ transform: ([TableFilter]) -> [TableFilter]) -> AppliedFilters? {
        AppliedFilters(filters: transform(filters), logicMode: logicMode, aloneFilterID: aloneFilterID)
    }

    // Order never changes which rows match, and with one condition neither does the logic mode.
    func selectsSameRows(as other: AppliedFilters) -> Bool {
        guard aloneFilterID == other.aloneFilterID, filters.count == other.filters.count else { return false }
        if filters.count > 1, logicMode != other.logicMode { return false }
        var unmatched = other.filters
        for row in filters {
            guard let index = unmatched.firstIndex(where: { $0.hasSameCondition(as: row) }) else { return false }
            unmatched.remove(at: index)
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case filters, logicMode, aloneFilterID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let filters = try container.decode([TableFilter].self, forKey: .filters)
        guard !filters.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .filters, in: container, debugDescription: "No applied filters")
        }
        self.filters = filters
        self.logicMode = try container.decodeIfPresent(FilterLogicMode.self, forKey: .logicMode) ?? .and
        self.aloneFilterID = try container.decodeIfPresent(UUID.self, forKey: .aloneFilterID)
    }
}

enum FilterPanelStatus: Equatable {
    case empty
    case notApplied
    case applied
    case appliedAlone
    case changesNotApplied
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
    // Still written because the previous stable reads only this flag and restores the checked rows;
    // absent in files from before it existed, where only an applied set was ever saved.
    var isApplied: Bool
    // What the grid was showing, so a row applied alone or edited since it ran restores as it ran.
    var applied: AppliedFilters?

    init(filters: [TableFilter], logicMode: FilterLogicMode = .and, applied: AppliedFilters?) {
        self.filters = filters
        self.logicMode = logicMode
        self.isApplied = applied != nil
        self.applied = applied
    }

    init(filters: [TableFilter], logicMode: FilterLogicMode = .and, isApplied: Bool = true) {
        self.filters = filters
        self.logicMode = logicMode
        self.isApplied = isApplied
        self.applied = nil
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           let filters = try? keyed.decode([TableFilter].self, forKey: .filters) {
            self.filters = filters
            self.logicMode = (try? keyed.decode(FilterLogicMode.self, forKey: .logicMode)) ?? .and
            self.isApplied = (try? keyed.decode(Bool.self, forKey: .isApplied)) ?? true
            self.applied = isApplied ? try? keyed.decode(AppliedFilters.self, forKey: .applied) : nil
            return
        }
        let single = try decoder.singleValueContainer()
        self.filters = try single.decode([TableFilter].self)
        self.logicMode = .and
        self.isApplied = true
        self.applied = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filters, forKey: .filters)
        try container.encode(logicMode, forKey: .logicMode)
        try container.encode(isApplied, forKey: .isApplied)
        try container.encodeIfPresent(applied, forKey: .applied)
    }

    private enum CodingKeys: String, CodingKey {
        case filters, logicMode, isApplied, applied
    }

    // A file from before `applied` was saved ran its checked rows.
    var restoredApplication: AppliedFilters? {
        guard isApplied else { return nil }
        return applied ?? .checkedRows(of: filters, logicMode: logicMode)
    }
}

extension TabFilterState {
    // A tab opened already filtered by these rows, all of them checked and running.
    static func applying(_ filters: [TableFilter], logicMode: FilterLogicMode) -> TabFilterState {
        var state = TabFilterState(isVisible: true)
        state.filters = filters
        state.filterLogicMode = logicMode
        state.applied = .checkedRows(of: filters, logicMode: logicMode)
        return state
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

    // An estimate measures the whole table, which is not the total of a narrowed list.
    func narrowsRows(browseSearchIsSupported: Bool) -> Bool {
        isFiltering || activeBrowseSearch(isSupported: browseSearchIsSupported) != nil
    }
}

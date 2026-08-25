//
//  MainContentCoordinator+GridDisplay.swift
//  TablePro
//
//  The display formats and the display order the data grid shows, resolved without the grid.
//

import Foundation
import TableProPluginKit

/// A resolved display order plus the inputs it was resolved from.
///
/// `dataRevision` is ticked by `TabSessionRegistry` on every row mutation, so a stale entry cannot
/// survive a change to the rows it was computed over. That is the point of stamping rather than
/// asking callers to remember a refresh.
struct DisplayOrderCacheEntry {
    let dataRevision: Int
    let valueFilter: GridValueFilterState
    let displayFormats: [ValueDisplayFormat?]
    let displayIDs: [RowID]?

    func matches(
        dataRevision: Int,
        valueFilter: GridValueFilterState,
        displayFormats: [ValueDisplayFormat?]
    ) -> Bool {
        self.dataRevision == dataRevision
            && self.valueFilter == valueFilter
            && self.displayFormats == displayFormats
    }
}

/// A tab's formatted-cell text, kept across the grid remounts a tab switch causes, plus the inputs
/// that decided it.
struct DisplayStateCacheEntry {
    let identity: DataGridDisplayIdentity
    let state: DataGridDisplayState
    var lastUsed: Int
}

extension MainContentCoordinator {
    /// The formatted text and viewport anchor for a tab's result, kept here because the grid that
    /// derives them is destroyed and rebuilt on every tab switch.
    ///
    /// A stale entry is replaced rather than repaired: the cache is keyed by row id, row ids are
    /// positional, and a new page reuses the ids of the one before it, so anything that can change
    /// what a position holds has to be part of the identity. It keys on `bufferEpoch` rather than
    /// `dataRevision` for exactly that reason: an in-place edit keeps every row id, and the grid
    /// already drops the one row it touched, so replacing the whole entry there would re-format the
    /// page after every keystroke that commits. (#2424)
    func displayState(for tab: QueryTab) -> DataGridDisplayState {
        let settings = AppSettingsManager.shared.dataGrid
        let tableRows = tabSessionRegistry.existingTableRows(for: tab.id)
        let identity = DataGridDisplayIdentity(
            bufferEpoch: tabSessionRegistry.session(for: tab.id)?.bufferEpoch ?? 0,
            resultSetId: tab.display.activeResultSetId,
            columns: tableRows?.columns ?? [],
            columnTypes: tableRows?.columnTypes ?? [],
            displayFormats: displayFormats(for: tab),
            dateFormat: settings.dateFormat,
            nullDisplay: settings.nullDisplay,
            smartValueDetection: settings.enableSmartValueDetection
        )

        displayStateClock &+= 1
        if let cached = displayStateCache[tab.id], cached.identity == identity {
            displayStateCache[tab.id]?.lastUsed = displayStateClock
            return cached.state
        }
        let state = DataGridDisplayState()
        displayStateCache[tab.id] = DisplayStateCacheEntry(
            identity: identity,
            state: state,
            lastUsed: displayStateClock
        )
        pruneDisplayStateCache()
        return state
    }

    /// Each entry holds a whole result's formatted text, budgeted at 64 MB by `RowDisplayCache`, so
    /// the tabs the user is actually moving between keep theirs and the rest give it back. The
    /// budget is the one inactive row data already uses, so the two do not disagree about how many
    /// background tabs are worth keeping.
    private func pruneDisplayStateCache() {
        let budget = MemoryPressureAdvisor.budgetForInactiveTabs() + 1
        guard displayStateCache.count > budget else { return }
        let ordered = displayStateCache.sorted { $0.value.lastUsed > $1.value.lastUsed }
        for entry in ordered.dropFirst(budget) {
            displayStateCache.removeValue(forKey: entry.key)
        }
    }

    /// The rows the grid is displaying, in display order, or nil when that is the storage order.
    ///
    /// Resolved from the tab rather than from the mounted grid. SwiftUI destroys an
    /// `NSViewRepresentable`'s coordinator the moment the representable leaves the view tree, so
    /// reading the order off `TableViewCoordinator` returned nil in JSON, Structure and Chart mode
    /// and silently degraded every caller to storage order. (#2251)
    func displayIDs(forTab tabId: UUID) -> [RowID]? {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return nil }
        guard tab.valueFilter.isActive else { return nil }

        let session = tabSessionRegistry.session(for: tabId)
        let dataRevision = session?.dataRevision ?? 0
        let formats = displayFormats(for: tab)

        if let cached = displayOrderCache[tabId],
           cached.matches(dataRevision: dataRevision, valueFilter: tab.valueFilter, displayFormats: formats) {
            return cached.displayIDs
        }

        let resolved = GridDisplayOrderResolver.resolve(
            tableRows: session?.tableRows ?? TableRows(),
            valueFilter: tab.valueFilter,
            displayFormats: formats,
            databaseType: connection.type
        )
        displayOrderCache[tabId] = DisplayOrderCacheEntry(
            dataRevision: dataRevision,
            valueFilter: tab.valueFilter,
            displayFormats: formats,
            displayIDs: resolved
        )
        return resolved
    }

    func setValueFilter(_ valueFilter: GridValueFilterState, forTab tabId: UUID) {
        guard tabManager.tabs.first(where: { $0.id == tabId })?.valueFilter != valueFilter else { return }
        tabManager.mutate(tabId: tabId) { $0.valueFilter = valueFilter }
    }

    /// Drops a value filter whose rows have been replaced wholesale.
    ///
    /// The filter stores the displayed strings the user picked out of the loaded rows, so it means
    /// nothing once those rows are gone. Left in place it narrows an unrelated result to nothing,
    /// and in JSON mode there is not even a header indicator to explain why.
    ///
    /// A mounted grid holds its own mirror of the filter and is told about the clear here rather
    /// than at the next view update, because `setActiveTableRows` drives the grid's full reload on
    /// the very next line. Left to the view update, that reload would resolve the new rows through
    /// the old filter, and pruning the old filter against the new columns would write it back onto
    /// the tab that was just cleared.
    func clearValueFilter(forTab tabId: UUID) {
        displayOrderCache.removeValue(forKey: tabId)
        if tabManager.selectedTabId == tabId {
            dataTabDelegate?.tableViewCoordinator?.adoptValueFilter(GridValueFilterState())
        }
        guard tabManager.tabs.first(where: { $0.id == tabId })?.valueFilter.isActive == true else { return }
        tabManager.mutate(tabId: tabId) { $0.valueFilter.clearAll() }
    }

    /// The per-column display formats for a tab's result, cached on the inputs that decide them.
    ///
    /// Lives here rather than in the view because the display order is matched on formatted values,
    /// and that has to resolve with no view mounted.
    func displayFormats(for tab: QueryTab) -> [ValueDisplayFormat?] {
        let settings = AppSettingsManager.shared.dataGrid
        let service = ValueDisplayFormatService.shared
        let smartDetectionEnabled = settings.enableSmartValueDetection
        let overridesVersion = service.overridesVersion
        let resultSetId = tab.display.activeResultSetId

        if let cached = displayFormatsCache[tab.id],
           cached.matches(
               schemaVersion: tab.schemaVersion,
               resultSetId: resultSetId,
               smartDetectionEnabled: smartDetectionEnabled,
               overridesVersion: overridesVersion
           ) {
            return cached.formats
        }

        let tableRows = tabSessionRegistry.existingTableRows(for: tab.id)
        let columns = tableRows?.columns ?? []
        let columnTypes = tableRows?.columnTypes ?? []
        guard !columns.isEmpty else { return [] }
        let storageKeys = ValueDisplayFormatColumnKey.storageKeys(for: columns)

        var detected: [ValueDisplayFormat?] = Array(repeating: nil, count: columns.count)
        if smartDetectionEnabled {
            let sampleRows: [[PluginCellValue]]? = {
                let rows: [[PluginCellValue]] = tableRows?.rows.prefix(10).map { Array($0.values) } ?? []
                return rows.isEmpty ? nil : rows
            }()
            detected = ValueDisplayDetector.detect(
                columns: columns,
                columnTypes: columnTypes,
                sampleValues: sampleRows
            )
            for index in detected.indices {
                guard let format = detected[index],
                      !format.isApplicable(
                          to: index < columnTypes.count ? columnTypes[index] : nil,
                          databaseType: connection.type
                      ) else { continue }
                detected[index] = nil
            }

            var autoMap: [String: ValueDisplayFormat] = [:]
            for (i, format) in detected.enumerated() where i < columns.count {
                if let format {
                    autoMap[storageKeys[i]] = format
                }
            }
            service.setAutoDetectedFormats(autoMap, scope: tab.tableContext.scope(connectionId: connectionId))
        } else {
            service.clearAutoDetectedFormats(scope: tab.tableContext.scope(connectionId: connectionId))
        }

        var merged = detected

        if let scope = tab.tableContext.scope(connectionId: connectionId),
           let overrides = ValueDisplayFormatStorage.shared.load(for: scope) {
            for (i, storageKey) in storageKeys.enumerated() {
                if let overrideFormat = overrides[storageKey],
                   overrideFormat.isApplicable(
                       to: i < columnTypes.count ? columnTypes[i] : nil,
                       databaseType: connection.type
                   ) {
                    while merged.count <= i { merged.append(nil) }
                    merged[i] = overrideFormat
                }
            }
        }

        let result = merged.contains(where: { $0 != nil }) ? merged : []
        displayFormatsCache[tab.id] = DisplayFormatsCacheEntry(
            schemaVersion: tab.schemaVersion,
            resultSetId: resultSetId,
            smartDetectionEnabled: smartDetectionEnabled,
            overridesVersion: overridesVersion,
            formats: result
        )
        return result
    }
}

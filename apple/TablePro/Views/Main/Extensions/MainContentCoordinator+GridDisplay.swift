//
//  MainContentCoordinator+GridDisplay.swift
//  TablePro
//
//  The display formats and the display order the data grid shows, resolved without the grid.
//

import AppKit
import Foundation
import TableProPluginKit
import TableProUtilities

extension MainContentCoordinator {
    // The rows the grid shows, in display order, or nil when that is the storage order. Read from the
    // tab's model, which resolves the order with no grid mounted (#2251).
    func displayIDs(forTab tabId: UUID) -> [RowID]? {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }), tab.valueFilter.isActive else { return nil }
        return gridModel(forTab: tabId).displayedRowIDs
    }

    func setValueFilter(_ valueFilter: GridValueFilterState, forTab tabId: UUID) {
        guard tabManager.tabs.first(where: { $0.id == tabId })?.valueFilter != valueFilter else { return }
        tabManager.mutate(tabId: tabId) { $0.valueFilter = valueFilter }
    }

    // Re-reading the same source can move or drop columns, so the filter follows its columns by name.
    func carryValueFilter(onto columns: [String], forTab tabId: UUID) {
        guard let current = tabManager.tabs.first(where: { $0.id == tabId })?.valueFilter,
              current.isActive else { return }
        // Keyed on the result, which is replaced only after these rows are installed.
        displayFormatsCache.removeValue(forKey: tabId)
        let carried = current.remapped(toColumns: columns)
        guard carried != current else { return }
        tabManager.mutate(tabId: tabId) { $0.valueFilter = carried }
    }

    // The filter holds displayed strings picked out of rows that are gone, so on new rows it narrows to nothing.
    func clearValueFilter(forTab tabId: UUID) {
        guard tabManager.tabs.first(where: { $0.id == tabId })?.valueFilter.isActive == true else { return }
        tabManager.mutate(tabId: tabId) { $0.valueFilter.clearAll() }
    }

    // Resolved here because the display order matches formatted values with no grid mounted.
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

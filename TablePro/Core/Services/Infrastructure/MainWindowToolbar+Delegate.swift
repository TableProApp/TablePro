//
//  MainWindowToolbar+Delegate.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

extension MainWindowToolbar {
    internal func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        Self.lifecycleLogger.info(
            "[open] toolbar delegate buildItem id=\(itemIdentifier.rawValue, privacy: .public) hasCoordinator=\(self.coordinator != nil)"
        )
        guard let coordinator else { return nil }

        switch itemIdentifier {
        case Self.sidebarToggle:
            return makeSidebarToggleItem()
        case Self.connectionGroup:
            let group = makeGroup(
                id: itemIdentifier,
                label: String(localized: "Connection"),
                subitems: [subitemConnection(), subitemDatabase()],
                content: HStack(spacing: 4) {
                    ConnectionToolbarButton(coordinator: coordinator)
                    DatabaseToolbarButton(coordinator: coordinator)
                    SessionContextToolbarButton(coordinator: coordinator)
                }
            )
            group.isNavigational = true
            return group
        case Self.principal:
            let item = hostingItem(
                id: itemIdentifier,
                label: "",
                symbol: nil,
                action: nil,
                keyEquivalent: "",
                modifiers: [],
                content: ToolbarPrincipalContent(
                    state: coordinator.toolbarState,
                    onSwitchDatabase: { [weak coordinator] in coordinator?.commandActions?.openDatabaseSwitcher() },
                    onCancelQuery: { [weak coordinator] in coordinator?.cancelCurrentQuery() },
                    onSafeModeChange: { [weak coordinator] level in coordinator?.setSafeModeLevel(level) }
                )
            )
            item.visibilityPriority = .high
            return item
        case Self.quickSwitcher:
            return hostingItem(
                id: itemIdentifier,
                label: String(localized: "Quick Switcher"),
                symbol: "magnifyingglass",
                action: #selector(performOpenQuickSwitcher(_:)),
                keyEquivalent: "o",
                modifiers: [.command, .shift],
                content: QuickSwitcherToolbarButton(coordinator: coordinator)
            )
        case Self.newTab:
            return hostingItem(
                id: itemIdentifier,
                label: String(localized: "New Tab"),
                symbol: "plus.rectangle",
                action: #selector(performNewTab(_:)),
                keyEquivalent: "t",
                modifiers: .command,
                content: NewTabToolbarButton(coordinator: coordinator)
            )
        case Self.previewSQL:
            return hostingItem(
                id: itemIdentifier,
                label: String(localized: "Preview"),
                symbol: "eye",
                action: #selector(performPreviewSQL(_:)),
                keyEquivalent: "p",
                modifiers: [.command, .shift],
                content: PreviewSQLToolbarButton(coordinator: coordinator)
            )
        case Self.results:
            return hostingItem(
                id: itemIdentifier,
                label: String(localized: "Results"),
                symbol: "rectangle.bottomhalf.inset.filled",
                action: #selector(performToggleResults(_:)),
                keyEquivalent: "r",
                modifiers: [.command, .option],
                content: ResultsToolbarButton(coordinator: coordinator)
            )
        case Self.inspector:
            let item = NSToolbarItem(itemIdentifier: Self.inspector)
            item.label = String(localized: "Inspector")
            item.paletteLabel = String(localized: "Inspector")
            return item
        case Self.dashboard:
            return hostingItem(
                id: itemIdentifier,
                label: String(localized: "Dashboard"),
                symbol: "gauge.with.dots.needle.33percent",
                action: #selector(performShowDashboard(_:)),
                keyEquivalent: "",
                modifiers: [],
                content: DashboardToolbarButton(coordinator: coordinator)
            )
        case Self.history:
            return hostingItem(
                id: itemIdentifier,
                label: String(localized: "History"),
                symbol: "clock",
                action: #selector(performToggleHistory(_:)),
                keyEquivalent: "y",
                modifiers: .command,
                content: HistoryToolbarButton(coordinator: coordinator)
            )
        case Self.refreshSaveGroup:
            return makeGroup(
                id: itemIdentifier,
                label: String(localized: "Refresh & Save"),
                subitems: [subitemRefresh(), subitemSaveChanges()],
                content: HStack(spacing: 4) {
                    RefreshToolbarButton(coordinator: coordinator)
                    SaveChangesToolbarButton(coordinator: coordinator)
                }
            )
        case Self.exportImportGroup:
            return makeGroup(
                id: itemIdentifier,
                label: String(localized: "Export & Import"),
                subitems: [subitemExport(), subitemImport()],
                content: HStack(spacing: 4) {
                    ExportToolbarButton(coordinator: coordinator)
                    ImportToolbarButton(coordinator: coordinator)
                }
            )
        default:
            return nil
        }
    }
}

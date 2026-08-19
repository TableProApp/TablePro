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
        switch itemIdentifier {
        case Self.sidebarToggle:
            return makeSidebarToggleItem(claimsSlot: Self.claimsItemSlot(willBeInsertedIntoToolbar: flag))
        case Self.connectionGroup:
            let group = makeGroup(
                id: itemIdentifier,
                label: String(localized: "Connection"),
                subitems: [subitemConnection(), subitemDatabase()],
                retainsController: Self.claimsItemSlot(willBeInsertedIntoToolbar: flag),
                content: HStack(spacing: 4) {
                    ConnectionToolbarSubjectButton(subject: subject)
                    DatabaseToolbarSubjectButton(subject: subject)
                    SessionContextToolbarSubjectButton(subject: subject)
                }
            )
            group.isNavigational = true
            return group
        case Self.principal:
            let item = hostingItem(
                id: itemIdentifier,
                label: String(localized: "Status"),
                symbol: nil,
                action: nil,
                keyEquivalent: "",
                modifiers: [],
                retainsController: Self.claimsItemSlot(willBeInsertedIntoToolbar: flag),
                content: ToolbarPrincipalSubjectContent(subject: subject)
            )
            item.visibilityPriority = .high
            item.toolTip = String(localized: "Connection status")
            return item
        case Self.quickSwitcher:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "Open Quickly"),
                symbol: "magnifyingglass",
                action: #selector(performOpenQuickSwitcher(_:)),
                shortcut: .quickSwitcher
            )
        case Self.newTab:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "New Tab"),
                symbol: "plus.rectangle",
                action: #selector(performNewTab(_:)),
                shortcut: .newTab,
                description: String(localized: "New Query Tab")
            )
        case Self.previewSQL:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "Preview"),
                symbol: "eye",
                action: #selector(performPreviewSQL(_:)),
                shortcut: .previewSQL,
                description: previewDescription
            )
        case Self.results:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "Results"),
                symbol: "rectangle.bottomhalf.inset.filled",
                action: #selector(performToggleResults(_:)),
                shortcut: .toggleResults,
                description: String(localized: "Toggle Results"),
                symbolProvider: { [weak self] in
                    self?.coordinator?.toolbarState.isResultsCollapsed == false
                        ? "rectangle.inset.filled"
                        : "rectangle.bottomhalf.inset.filled"
                }
            )
        case Self.dashboard:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "Dashboard"),
                symbol: "gauge.with.dots.needle.33percent",
                action: #selector(performShowDashboard(_:)),
                description: String(localized: "Server Dashboard")
            )
        case Self.history:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "History"),
                symbol: "clock",
                action: #selector(performToggleHistory(_:)),
                shortcut: .toggleHistory,
                description: String(localized: "Toggle Query History")
            )
        case Self.refreshSaveGroup:
            return makeNativeGroup(
                id: itemIdentifier,
                label: String(localized: "Refresh & Save"),
                subitems: [subitemRefresh(), subitemSaveChanges()]
            )
        case Self.exportImportGroup:
            return makeNativeGroup(
                id: itemIdentifier,
                label: String(localized: "Export & Import"),
                subitems: [subitemExport(), subitemImport()]
            )
        default:
            return nil
        }
    }
}

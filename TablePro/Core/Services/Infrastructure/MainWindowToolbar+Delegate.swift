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
            return makeSidebarToggleItem()
        case Self.connectionGroup:
            let group = makeGroup(
                id: itemIdentifier,
                label: String(localized: "Connection"),
                subitems: [subitemConnection(), subitemDatabase()],
                retainsController: Self.retainsHostingController(willBeInsertedIntoToolbar: flag),
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
                retainsController: Self.retainsHostingController(willBeInsertedIntoToolbar: flag),
                content: ToolbarPrincipalSubjectContent(subject: subject)
            )
            item.visibilityPriority = .high
            item.toolTip = String(localized: "Connection status")
            return item
        case Self.quickSwitcher:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "Quick Switcher"),
                symbol: "magnifyingglass",
                action: #selector(performOpenQuickSwitcher(_:)),
                keyEquivalent: "o",
                modifiers: [.command, .shift],
                shortcut: .quickSwitcher
            )
        case Self.newTab:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "New Tab"),
                symbol: "plus.rectangle",
                action: #selector(performNewTab(_:)),
                keyEquivalent: "t",
                modifiers: .command,
                shortcut: .newTab,
                description: String(localized: "New Query Tab")
            )
        case Self.previewSQL:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "Preview"),
                symbol: "eye",
                action: #selector(performPreviewSQL(_:)),
                keyEquivalent: "p",
                modifiers: [.command, .shift],
                shortcut: .previewSQL,
                description: previewDescription
            )
        case Self.results:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "Results"),
                symbol: "rectangle.bottomhalf.inset.filled",
                action: #selector(performToggleResults(_:)),
                keyEquivalent: "r",
                modifiers: [.command, .option],
                shortcut: .toggleResults,
                description: String(localized: "Toggle Results"),
                symbolProvider: { [weak self] in
                    self?.coordinator?.toolbarState.isResultsCollapsed == false
                        ? "rectangle.inset.filled"
                        : "rectangle.bottomhalf.inset.filled"
                }
            )
        case Self.inspector:
            let item = NSToolbarItem(itemIdentifier: Self.inspector)
            item.label = String(localized: "Inspector")
            item.paletteLabel = String(localized: "Inspector")
            return item
        case Self.dashboard:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "Dashboard"),
                symbol: "gauge.with.dots.needle.33percent",
                action: #selector(performShowDashboard(_:)),
                keyEquivalent: "",
                modifiers: [],
                description: String(localized: "Server Dashboard")
            )
        case Self.history:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "History"),
                symbol: "clock",
                action: #selector(performToggleHistory(_:)),
                keyEquivalent: "y",
                modifiers: .command,
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

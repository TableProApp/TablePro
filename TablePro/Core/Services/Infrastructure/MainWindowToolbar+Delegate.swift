//
//  MainWindowToolbar+Delegate.swift
//  TablePro
//

import AppKit
import os

extension MainWindowToolbar {
    /// Builds a new item on every call and keeps none of them.
    ///
    /// Customize Toolbar asks again for every allowed identifier, and a delegate that handed back
    /// a cached instance handed back the one the context had hidden: measured on macOS 27, a
    /// dragged-in item that was the same instance arrived with `isHidden` still true, took its slot
    /// and drew nothing. The palette's stale visibility state rides the item instance as well, so
    /// an instance shared across vends would carry it into every later arrangement.
    internal func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        Self.lifecycleLogger.info(
            "[open] toolbar delegate buildItem id=\(itemIdentifier.rawValue, privacy: .public) hasCoordinator=\(self.coordinator != nil)"
        )
        guard let item = buildItem(itemIdentifier) else { return nil }
        applyVisibilityPriority(to: item)
        return item
    }

    /// An item the palette is about to drop in has to take the context the window is in, and the
    /// hideable ones are the ones that care. Measured, opening and closing the palette without a
    /// change posts nothing, so this costs nothing when the user only looks.
    internal func toolbarWillAddItem(_ notification: Notification) {
        scheduleVisibilityReapply()
    }

    private func buildItem(_ itemIdentifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.inspector:
            /// AppKit builds `.toggleInspector` itself and never asks the delegate for it, so this
            /// arm is dead on macOS 14. Below that the identifier is app-owned, and an identifier
            /// the delegate does not answer for simply never appears in the toolbar.
            guard #unavailable(macOS 14.0) else { return nil }
            /// The action is the split controller's, so it is forwarded rather than named directly.
            /// An `NSToolbarItem` whose explicit target does not respond to its selector is disabled
            /// after `validateVisibleItems`, measured, even with a responder in the chain that does:
            /// the item was drawn permanently dimmed on the app's minimum OS and never toggled
            /// anything.
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "Inspector"),
                symbol: "sidebar.trailing",
                action: #selector(forwardToggleInspector(_:)),
                shortcut: .toggleInspector,
                description: String(localized: "Toggle Inspector")
            )
        case Self.connection:
            return makeConnectionItem()
        case Self.database:
            return makeDatabaseItem()
        case Self.refresh:
            return makeRefreshItem()
        case Self.saveChanges:
            return makeSaveChangesItem()
        case Self.actions:
            return makeActionsItem()
        case Self.safeMode:
            return makeSafeModeItem()
        case Self.backForwardGroup:
            /// `isNavigational` is what puts back and forward on the leading edge of the content
            /// title area, where Finder and Safari keep them, instead of in the slot the identifier
            /// list nominally gives them.
            ///
            /// Both subitems are installed unconditionally and stay installed. Availability is
            /// `isEnabled`, written by `validateToolbarItem(_:)`, never presence: measured on three
            /// running Apple apps, Xcode, Finder in column view and System Settings all keep the
            /// 75pt capsule and dim the direction that has nowhere to go.
            let group = makeNativeGroup(
                id: itemIdentifier,
                label: String(localized: "Navigation"),
                subitems: [makeNavigateBackItem(), makeNavigateForwardItem()]
            )
            group.isNavigational = true
            return group
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
        case Self.assistant:
            return menuOnlyItem(
                id: itemIdentifier,
                label: String(localized: "Assistant"),
                symbol: "sparkles",
                action: #selector(performToggleAssistant(_:)),
                shortcut: .toggleAssistant,
                description: String(localized: "Toggle Assistant")
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
        case Self.exportTables:
            return makeExportItem()
        case Self.importTables:
            return makeImportItem()
        case Self.addRow:
            return makeAddRowItem()
        case Self.restorePreviousValues:
            return makeRestorePreviousValuesItem()
        case Self.newTab:
            return makeNewTabItem()
        case Self.quickSwitcher:
            return makeQuickSwitcherItem()
        default:
            return nil
        }
    }
}

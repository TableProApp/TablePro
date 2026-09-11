//
//  MainWindowToolbar+Delegate.swift
//  TablePro
//

import AppKit
import os

extension MainWindowToolbar {
    internal func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        Self.lifecycleLogger.info(
            "[open] toolbar delegate buildItem id=\(itemIdentifier.rawValue, privacy: .public) hasCoordinator=\(self.coordinator != nil)"
        )
        guard let item = buildItem(itemIdentifier, willBeInsertedIntoToolbar: flag) else { return nil }
        applyVisibilityPriority(to: item)
        return item
    }

    private func buildItem(
        _ itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.sidebarToggle:
            return makeSidebarToggleItem(claimsSlot: Self.claimsItemSlot(willBeInsertedIntoToolbar: flag))
        case Self.contentMode:
            return makeContentModeItem(claimsSlot: Self.claimsItemSlot(willBeInsertedIntoToolbar: flag))
        case Self.backForwardGroup:
            /// `isNavigational` is what puts back and forward on the leading edge of the content
            /// title area, where Finder and Safari keep them, instead of in the slot the identifier
            /// list nominally gives them.
            ///
            /// Both subitems are installed unconditionally and stay installed. Availability is
            /// `isEnabled`, written by `validateToolbarItem(_:)`, never presence: measured on three
            /// running Apple apps, Xcode, Finder in column view and System Settings all keep the
            /// 75pt capsule and dim the direction that has nowhere to go. Emptying the group
            /// instead put the pair behind state that is `@ObservationIgnored`, so once hidden it
            /// did not come back until the user switched tabs.
            let group = makeNativeGroup(
                id: itemIdentifier,
                label: String(localized: "Navigation"),
                subitems: [subitemNavigateBack(), subitemNavigateForward()]
            )
            group.isNavigational = true
            return group
        case Self.connectionGroup:
            /// Native, like every other group here. As a view-backed group it drew a hosted SwiftUI
            /// row and its subitems were inert: the header is explicit that a property set on the
            /// parent, "such as label or view, apply to the entire item", so neither subitem
            /// reached the overflow menu, the customization palette or `validate()`.
            ///
            /// Not navigational, unlike back and forward. `isNavigational` asks AppKit to lift an
            /// item to the leading edge of the content area, which is the opposite of what
            /// `centeredItemIdentifiers` asks for, and this group is the centred one.
            return makeNativeGroup(
                id: itemIdentifier,
                label: String(localized: "Connection"),
                subitems: [subitemConnection(), subitemDatabase()]
            )
        case TransportRateToolbarItem.identifier:
            /// Beside the centred pair, never inside it. A group is laid out around its own
            /// midpoint, so a readout inside this one pushed the two capsules off centre by half
            /// the readout's width; measured as its own adjacent item, the group sits where it
            /// sits with no readout at all and the figure lands 6.0pt past its trailing edge.
            return transportRateGroup
        case Self.safeMode:
            return subitemSafeMode()
        case Self.editorGroup:
            return makeNativeGroup(
                id: itemIdentifier,
                label: String(localized: "Editor"),
                subitems: [subitemNewTab(), subitemQuickSwitcher()]
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
        case Self.refreshSaveGroup:
            return makeNativeGroup(
                id: itemIdentifier,
                label: String(localized: "Table Actions"),
                subitems: [
                    subitemRefresh(), subitemSaveChanges(), subitemAddRow(),
                    subitemRestorePreviousValues(),
                ]
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

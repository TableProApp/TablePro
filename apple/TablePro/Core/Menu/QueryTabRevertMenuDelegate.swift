//
//  QueryTabRevertMenuDelegate.swift
//  TablePro
//

import AppKit

internal struct QueryTabRevertChoice: Equatable {
    let tabId: UUID
    let versionId: Int64
}

// File > Revert To, filled for the selected query tab when it opens. Items carry no target, so the window validates them.
@MainActor
internal final class QueryTabRevertMenuDelegate: NSObject, NSMenuDelegate {
    static let revertAction = #selector(MainSplitViewController.revertToQueryTabVersion(_:))
    static let browseAction = #selector(MainSplitViewController.browseQueryTabVersions(_:))
    static let recentVersionLimit = 10

    // Resolved when the menu opens, so building the menu bar touches no store.
    private let storage: QueryTabVersionStorage?

    init(storage: QueryTabVersionStorage? = nil) {
        self.storage = storage
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let controller = NSApp.target(forAction: Self.browseAction, to: nil, from: nil) as? MainSplitViewController
        let tabId = controller?.selectedQueryTabId
        let store = storage ?? .shared
        let summaries = tabId.map { store.summaries(tabId: $0, limit: Self.recentVersionLimit) } ?? []
        Self.fill(menu, tabId: tabId, summaries: summaries)
    }

    static func fill(_ menu: NSMenu, tabId: UUID?, summaries: [QueryTabVersionSummary]) {
        menu.removeAllItems()
        if let tabId, !summaries.isEmpty {
            for summary in summaries {
                menu.addItem(item(for: summary, tabId: tabId))
            }
        } else {
            menu.addItem(MenuPlaceholder.item())
        }
        menu.addItem(.separator())
        let browse = NSMenuItem(title: String(localized: "Browse All Versions…"), action: browseAction, keyEquivalent: "")
        browse.target = nil
        menu.addItem(browse)
    }

    static func item(for summary: QueryTabVersionSummary, tabId: UUID) -> NSMenuItem {
        let entry = QueryTabVersionHistoryProvider.entry(for: summary)
        let item = NSMenuItem(title: VersionHistoryFormatting.menuTitle(for: entry), action: revertAction, keyEquivalent: "")
        item.target = nil
        item.representedObject = QueryTabRevertChoice(tabId: tabId, versionId: summary.id)
        return item
    }

    // Keeps AppKit's key-equivalent search from reading the store on every modified keystroke.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}

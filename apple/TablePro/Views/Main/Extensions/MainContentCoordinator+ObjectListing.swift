//
//  MainContentCoordinator+ObjectListing.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    /// A sidebar selection previews a container's objects and the next selection replaces them; a
    /// menu command opens them to keep, and brings a tab already open up to date.
    func showObjects(_ target: DatabaseTreeObjectGroup, asPreview: Bool) {
        let schemaName = target.schema?.nilIfEmpty
        let isOpen = tabManager.tableListingTab(databaseName: target.database, schemaName: schemaName) != nil
        let replaced = asPreview && !isOpen ? replaceablePreview : nil
        if let replaced {
            releasePreviewForReplacement(replaced)
        }
        let tabId = tabManager.addTableListingTab(
            title: listingTitle(kind: target.kind, schemaName: schemaName),
            databaseName: target.database,
            schemaName: schemaName,
            kind: target.kind,
            isPreview: asPreview,
            replacing: replaced?.id
        )
        guard !asPreview else { return }
        /// Asking again for a listing already open brings it up to date, the way Refresh would. A tab
        /// opened just now loads when its view first appears, and nothing is listening for this yet.
        AppEvents.shared.tabRefreshRequested.send(tabId)
    }

    /// The kind picker is the user using the tab, so it keeps a preview.
    func selectListingKind(_ kind: SidebarObjectKind, inTab tabId: UUID) {
        tabManager.promotePreviewTab(id: tabId)
        retargetListing(tabId, to: kind)
    }

    /// An engine that stopped fetching the tab's kind shows Tables; that is not the user keeping the tab.
    func adoptListingKind(_ kind: SidebarObjectKind, inTab tabId: UUID) {
        retargetListing(tabId, to: kind)
    }

    /// A row reaches its object the way the sidebar's row does, in the tab's own database. The tab is
    /// kept first: a table opened from a preview would otherwise take the preview's place.
    func performListingAction(_ action: ObjectListingAction, fromTab tabId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId && $0.tabType == .tableListing }) else { return }
        tabManager.promotePreviewTab(id: tabId)
        let database = tab.tableContext.databaseName
        switch action {
        case .open(let item):
            openListedRelation(item, database: database, showStructure: false, forceNewTab: false)
        case .openInNewTab(let item):
            openListedRelation(item, database: database, showStructure: false, forceNewTab: true)
        case .showStructure(let item):
            openListedRelation(item, database: database, showStructure: true, forceNewTab: false)
        case .showSource(let item):
            guard let objectRef = item.sourceRef(database: database) else { return }
            showObjectSource(objectRef)
        case .copyNames(let names):
            ClipboardService.shared.writeText(names.joined(separator: ","))
        }
    }

    private func openListedRelation(_ item: ObjectListingItem, database: String, showStructure: Bool, forceNewTab: Bool) {
        guard case .relation(let name, let schema, let type) = item else { return }
        openTableTab(
            name,
            schema: schema,
            database: database,
            showStructure: showStructure,
            isView: !type.allowsRowEditing,
            objectType: type,
            forceNonPreview: true,
            activateGridFocus: showStructure,
            forceNewTab: forceNewTab
        )
    }

    private func retargetListing(_ tabId: UUID, to kind: SidebarObjectKind) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId && $0.tabType == .tableListing }) else { return }
        tabManager.setTableListingKind(
            kind,
            title: listingTitle(kind: kind, schemaName: tab.tableContext.schemaName),
            tabId: tabId
        )
    }

    private func listingTitle(kind: SidebarObjectKind, schemaName: String?) -> String {
        QueryTabManager.tableListingTitle(
            kindTitle: kind.title(tableEntityName: PluginManager.shared.tableEntityName(for: connection.type)),
            schemaName: schemaName
        )
    }

    /// Kept, pinned and busy tabs are never taken over: the rule a table preview follows.
    private var replaceablePreview: QueryTab? {
        guard let tab = tabManager.selectedTab, tab.isPreview, isActiveTabReusable else { return nil }
        return tab
    }
}

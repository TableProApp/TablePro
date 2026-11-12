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
        let landing = tabManager.tableListingLanding(
            databaseName: target.database, schemaName: schemaName, kind: target.kind, isPreview: asPreview
        )
        let replaced = asPreview && landing == nil ? replaceablePreview : nil
        if let replaced {
            releasePreviewForReplacement(replaced)
        }
        // The kept listing takes a request to keep, so the preview beside it goes the way a replaced one does.
        if let closing = landing?.closesPreviewId.flatMap({ id in tabManager.tabs.first { $0.id == id } }) {
            releasePreviewForReplacement(closing)
        }
        let tabId = tabManager.addTableListingTab(
            title: QueryTabManager.tableListingTitle(schemaName: schemaName),
            databaseName: target.database,
            schemaName: schemaName,
            kind: target.kind,
            isPreview: asPreview,
            replacing: replaced?.id
        )
        guard !asPreview else { return }
        /// Asking again for a listing already open brings it up to date, the way Refresh would. A tab
        /// opened just now loads when its view first appears, and nothing is listening for this yet.
        /// One moved to another kind draws that kind's model only after this returns, so the store
        /// holds the request for that model instead of letting the outgoing one take it.
        if landing != nil {
            let kind = ObjectListingKinds.effective(target.kind, declared: connection.type.declaredObjectKinds)
            tableListingModels.expectReread(
                forTab: tabId,
                target: DatabaseTreeObjectGroup(database: target.database, schema: schemaName, kind: kind)
            )
        }
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
        let schema = tab.tableContext.schemaName
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
        case .createTable:
            createNewTable(databaseName: database, schemaName: schema)
        case .importData:
            // An import writes into the browsed container, so the tab's container is reached first,
            // as the sidebar's own Import does.
            Task { @MainActor [weak self] in
                await self?.switchContainers(database: database, schema: schema)
                self?.openImportPanel()
            }
        case .export(let items):
            let refs = listingTableRefs(items, in: tab)
            guard let first = refs.first else { return }
            let scope = ExportPreselection.scope(
                for: first,
                grouping: PluginManager.shared.databaseGroupingStrategy(for: connection.type)
            )
            Task { @MainActor [weak self] in
                await self?.switchContainers(database: database, schema: schema)
                self?.openExportDialog(preselectedTableNames: Set(refs.map(\.table.name)), scope: scope)
            }
        case .drop(let items):
            let refs = listingTableRefs(items, in: tab)
            guard !refs.isEmpty, !safeModeLevel.blocksAllWrites else { return }
            // The sidebar's own path: it asks before it queues the drop, and Save runs it against the
            // browsed database, so the tab's container is reached first.
            Task { @MainActor [weak self] in
                await self?.switchContainers(database: database, schema: schema)
                guard let self else { return }
                sidebarViewModel?.batchToggleDelete(refs: refs, from: windowSidebarState)
            }
        }
    }

    /// What the tool strip of `tabId` can offer for `items`, its selected objects.
    func listingCommandFacts(for items: [ObjectListingItem], inTab tabId: UUID) -> ObjectListingCommandFacts {
        let isReadOnly = safeModeLevel.blocksAllWrites
        guard !isReadOnly else { return ObjectListingCommandFacts(isReadOnly: true) }
        let driver = DatabaseManager.shared.driver(for: connectionId)
        var facts = ObjectListingCommandFacts(isReadOnly: false)
        facts.canCreateTable = CreateTableEligibility.canCreateTable(with: driver)
        facts.canImport = importFormatLookup.supportsImport(connection.type)
            && !importFormatLookup.offeredFormats(connection.type).isEmpty
        if let adapter = driver as? PluginDriverAdapter,
           let tab = tabManager.tabs.first(where: { $0.id == tabId && $0.tabType == .tableListing }) {
            let refs = listingTableRefs(items, in: tab)
            facts.canDropSelection = refs.count == items.count && TableOperationEligibility.canDrop(
                refs,
                context: adapter.tableOperationEligibility(for: refs, isReadOnly: false)
            )
        }
        return facts
    }

    /// The refs the sidebar's commands take for the listed relations. Where the sidebar lists the
    /// object, its own `TableInfo` is used, so a queued drop marks the same row there.
    func listingTableRefs(_ items: [ObjectListingItem], in tab: QueryTab) -> [DatabaseTreeTableRef] {
        let database = tab.tableContext.databaseName
        let schema = tab.tableContext.schemaName
        let listed = DatabaseTreeMetadataService.shared.tables(connectionId: connectionId, database: database, schema: schema)
        return items.compactMap { item in
            guard case .relation(let name, let itemSchema, let type) = item else { return nil }
            let kind = SidebarObjectKind.resolve(tableType: type)
            let table = listed.first { candidate in
                candidate.name == name
                    && SidebarObjectKind.resolve(tableType: candidate.type) == kind
                    && (candidate.schema == nil || itemSchema == nil || candidate.schema == itemSchema)
            } ?? TableInfo(name: name, type: type, rowCount: nil, schema: itemSchema)
            return DatabaseTreeTableRef(database: database, schema: schema ?? table.schema, table: table)
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
            title: QueryTabManager.tableListingTitle(schemaName: tab.tableContext.schemaName),
            tabId: tabId
        )
    }

    /// Kept, pinned and busy tabs are never taken over: the rule a table preview follows.
    private var replaceablePreview: QueryTab? {
        guard let tab = tabManager.selectedTab, tab.isPreview, isActiveTabReusable else { return nil }
        return tab
    }
}

//
//  TableListingViewModel.swift
//  TablePro
//

import AppKit
import Combine
import Foundation

internal struct ObjectListingCount: Equatable {
    let shown: Int
    let total: Int
}

@MainActor
internal final class TableListingViewModel: ObservableObject {
    @Published private(set) var state: MetadataLoadState<TableListing> = .idle
    @Published private(set) var isRefreshing = false
    /// A read that ended cancelled with nothing on screen: no read is on its way, so the pane offers
    /// Try Again instead of a spinner that would wait for nothing.
    @Published private(set) var wasInterrupted = false
    @Published private(set) var count: ObjectListingCount?
    // View state: it hides rows and fetches nothing.
    @Published var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            showRows()
            onInteraction()
        }
    }

    // Outlives the tab's view, so the sort, the selection and the column widths survive a tab switch.
    let grid = HeldRowsGridAdapter(configuration: DataGridConfiguration(), sortsHeldRows: true)
    let target: DatabaseTreeObjectGroup

    private let scope: DatabaseScope
    private let loader: TableListingLoader
    private let metadataProvider: any ScopedMetadataProviding
    private let objectSource: any CatalogObjectListSource
    private let perform: (ObjectListingAction) -> Void
    private let onInteraction: () -> Void
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var refreshSubscription: AnyCancellable?
    private var firstLoadRereads = false

    init(
        tabId: UUID,
        scope: DatabaseScope,
        kind: SidebarObjectKind = .table,
        loader: TableListingLoader,
        metadataProvider: any ScopedMetadataProviding = DatabaseManager.shared,
        objectSource: any CatalogObjectListSource = DatabaseTreeMetadataService.shared,
        refreshRequests: AnyPublisher<UUID, Never> = AppEvents.shared.tabRefreshRequested.eraseToAnyPublisher(),
        perform: @escaping (ObjectListingAction) -> Void = { _ in },
        onInteraction: @escaping () -> Void = {}
    ) {
        self.scope = scope
        self.target = DatabaseTreeObjectGroup(database: scope.database, schema: scope.schema, kind: kind)
        self.loader = loader
        self.metadataProvider = metadataProvider
        self.objectSource = objectSource
        self.perform = perform
        self.onInteraction = onInteraction
        refreshSubscription = refreshRequests
            .filter { $0 == tabId }
            .sink { [weak self] _ in self?.reload() }
        grid.onSortChange = { [weak self] _ in self?.onInteraction() }
        grid.rowMenuItems = { [weak self] rowIDs, clicked in
            self?.menuItems(for: rowIDs, clicked: clicked) ?? []
        }
        grid.opensRow = { [weak self] rowID in self?.open(rowID) }
    }

    /// Whether each row names an object, which the name filter and the row commands need.
    var rowsNameObjects: Bool {
        state.value.map { !$0.items.isEmpty } ?? false
    }

    @discardableResult
    func loadIfNeeded() -> Task<Void, Never>? {
        guard case .idle = state else { return nil }
        return load(rereading: firstLoadRereads)
    }

    /// The tab was asked for fresh rows before this model existed, so its first load asks the server
    /// rather than taking the list the sidebar holds.
    func rereadOnFirstLoad() {
        firstLoadRereads = true
    }

    // Refresh and Try Again ask the server again; the first load takes a list the sidebar already holds.
    @discardableResult
    func reload() -> Task<Void, Never> {
        load(rereading: true)
    }

    func cancel() {
        loadTask?.cancel()
        generation &+= 1
        isRefreshing = false
        wasInterrupted = false
        if case .loading = state {
            state = .idle
        }
    }

    // The tab moved to another container or kind: nothing shows this model again, so it stops without publishing.
    func retire() {
        loadTask?.cancel()
        generation &+= 1
        refreshSubscription = nil
    }

    private func load(rereading: Bool) -> Task<Void, Never> {
        loadTask?.cancel()
        generation &+= 1
        let token = generation
        state = state.enteringLoad
        isRefreshing = true
        wasInterrupted = false

        let scope = scope
        let kind = target.kind
        let loader = loader
        let provider = metadataProvider
        let source = objectSource
        let task = Task { [weak self] in
            let outcome: MetadataFetchOutcome<TableListing>
            if kind == .table {
                outcome = await loader.fetch(scope: scope, from: provider)
            } else {
                var read = await source.objects(kind.category, in: scope, rereading: rereading)
                // The sidebar's own reads can supersede this one. With nothing on screen, read once more,
                // which joins the newest read rather than starting another.
                if case .cancelled = read, self?.awaitsFirstRows(token) == true {
                    read = await source.objects(kind.category, in: scope, rereading: false)
                }
                switch read {
                case .fetched(let list):
                    outcome = .fetched(ObjectListingRows.listing(kind: kind, from: list, scope: scope))
                case .failed(let message):
                    outcome = .failed(message)
                case .cancelled:
                    outcome = .cancelled
                }
            }
            self?.commit(outcome, token: token)
        }
        loadTask = task
        return task
    }

    private func awaitsFirstRows(_ token: Int) -> Bool {
        guard token == generation, !Task.isCancelled else { return false }
        if case .loading = state { return true }
        return false
    }

    private func commit(_ outcome: MetadataFetchOutcome<TableListing>, token: Int) {
        guard token == generation else { return }
        isRefreshing = false
        let previous = state.value
        state = state.settled(by: outcome, discardingValue: false)
        // A cancel from here bumps the generation, so this one came from elsewhere and nothing else is coming.
        if case .cancelled = outcome, case .idle = state {
            wasInterrupted = true
        }
        showRows(replacing: previous)
    }

    /// The grid keeps its selection by row id, which is a position here, so rows replacing `previous`
    /// carry it to the same objects: Return and the menu act on what the reader picked.
    private func showRows(replacing previous: TableListing? = nil) {
        guard let listing = state.value else {
            count = nil
            return
        }
        let shown = ObjectListingFilter.rows(of: listing, matching: filterText)
        count = ObjectListingCount(shown: shown.count, total: listing.rows.count)
        grid.setRows(shown, carryingSelection: previous.flatMap { listing.rowIDs(carriedFrom: $0) })
    }

    private func menuItems(for rowIDs: [RowID], clicked: RowID) -> [NSMenuItem] {
        guard let items = state.value?.items, let clickedItem = items[clicked] else { return [] }
        let targets = rowIDs.compactMap { items[$0] }
        return ObjectListingMenu.commands(clicked: clickedItem, targets: targets).map { command in
            ClosureMenuTarget.item(title: command.title) { [weak self] in self?.run(command.action) }
        }
    }

    private func open(_ rowID: RowID) {
        guard let item = state.value?.items[rowID] else { return }
        run(ObjectListingMenu.primaryAction(for: item))
    }

    private func run(_ action: ObjectListingAction) {
        onInteraction()
        perform(action)
    }
}

@MainActor
internal final class TableListingModelStore {
    private var models: [UUID: TableListingViewModel] = [:]
    private var pendingRereads: [UUID: DatabaseTreeObjectGroup] = [:]

    /// A tab keeps its model while it lists the same container and kind. A retarget gets a fresh one,
    /// so another kind's rows never stand in for the new kind's while it loads.
    func model(
        forTab tabId: UUID,
        target: DatabaseTreeObjectGroup,
        make: () -> TableListingViewModel
    ) -> TableListingViewModel {
        if let existing = models[tabId] {
            if existing.target == target {
                return existing
            }
            existing.retire()
        }
        let model = make()
        if pendingRereads.removeValue(forKey: tabId) == target {
            model.rereadOnFirstLoad()
        }
        models[tabId] = model
        return model
    }

    /// A command asked the tab for fresh rows of `target`. A model already listing it takes the
    /// request as a refresh event. Any other model goes now, so that event does not reach it, and the
    /// model the tab's next draw makes for `target` reads it again rather than taking the sidebar's list.
    func expectReread(forTab tabId: UUID, target: DatabaseTreeObjectGroup) {
        guard models[tabId]?.target != target else { return }
        models.removeValue(forKey: tabId)?.retire()
        pendingRereads[tabId] = target
    }

    func retainTabs(_ openTabIds: Set<UUID>) {
        for (tabId, model) in models where !openTabIds.contains(tabId) {
            model.cancel()
        }
        models = models.filter { openTabIds.contains($0.key) }
        pendingRereads = pendingRereads.filter { openTabIds.contains($0.key) }
    }
}

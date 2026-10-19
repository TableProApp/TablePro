//
//  TableListingViewModel.swift
//  TablePro
//

import Combine
import Foundation

/// The rows of one listing tab, and what the reader did with its grid.
///
/// A refresh keeps the rows on screen until new ones land, and a failed refresh keeps them too. A load
/// that a newer one has superseded, or that was cancelled, commits nothing, whatever it came back with.
@MainActor
internal final class TableListingViewModel: ObservableObject {
    @Published private(set) var state: MetadataLoadState<TableListing> = .idle
    /// Moves each time a load lands, so the grid redraws rows that changed under the same tab.
    @Published private(set) var revision = 0

    @Published var sortState = SortState()
    @Published var selectedRows: Set<Int> = []
    @Published var columnLayout = ColumnLayoutState()
    let changeManager = AnyChangeManager(DataChangeManager())
    let gridDelegate = HeldRowsGridDelegate()

    private let scope: DatabaseScope
    private let loader: TableListingLoader
    private let metadataProvider: any ScopedMetadataProviding
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var refreshSubscription: AnyCancellable?

    init(
        tabId: UUID,
        scope: DatabaseScope,
        loader: TableListingLoader,
        metadataProvider: any ScopedMetadataProviding = DatabaseManager.shared,
        refreshRequests: AnyPublisher<UUID, Never> = AppEvents.shared.tableListingRefreshRequested.eraseToAnyPublisher()
    ) {
        self.scope = scope
        self.loader = loader
        self.metadataProvider = metadataProvider
        /// Heard here rather than by the view, which exists only while its tab is selected: asking again for
        /// a listing in a tab behind another one selects it and refreshes it in the same turn.
        refreshSubscription = refreshRequests
            .filter { $0 == tabId }
            .sink { [weak self] _ in self?.reload() }
        gridDelegate.onSortStateChanged = { [weak self] in self?.sortState = $0 }
    }

    /// The view's task runs again every time the tab comes back, so a listing already on screen or on its
    /// way is left alone. A cancelled load settles back to idle, and runs again here.
    @discardableResult
    func loadIfNeeded() -> Task<Void, Never>? {
        guard case .idle = state else { return nil }
        return reload()
    }

    @discardableResult
    func reload() -> Task<Void, Never> {
        loadTask?.cancel()
        generation &+= 1
        let token = generation
        state = state.enteringLoad

        let scope = scope
        let loader = loader
        let provider = metadataProvider
        let task = Task { [weak self] in
            let outcome = await loader.fetch(scope: scope, from: provider)
            self?.commit(outcome, token: token)
        }
        loadTask = task
        return task
    }

    /// For a closed tab: its load is left to nobody, and nothing it returns may land.
    func cancel() {
        loadTask?.cancel()
        generation &+= 1
        if case .loading = state {
            state = .idle
        }
    }

    private func commit(_ outcome: MetadataFetchOutcome<TableListing>, token: Int) {
        guard token == generation else { return }
        state = state.settled(by: outcome, discardingValue: false)
        revision &+= 1
    }
}

/// The listing models of a window's tabs, kept for as long as their tab is open.
///
/// Only the selected tab's view exists, so a model the view held went with every switch to another tab,
/// and the rows, the sort and the column widths with it, and coming back listed the tables again.
@MainActor
internal final class TableListingModelStore {
    private var models: [UUID: TableListingViewModel] = [:]

    func model(forTab tabId: UUID, make: () -> TableListingViewModel) -> TableListingViewModel {
        if let existing = models[tabId] {
            return existing
        }
        let model = make()
        models[tabId] = model
        return model
    }

    /// A closed tab's load is cancelled rather than left running for nobody on a metadata connection the
    /// sidebar and the next listing wait on.
    func retainTabs(_ openTabIds: Set<UUID>) {
        for (tabId, model) in models where !openTabIds.contains(tabId) {
            model.cancel()
        }
        models = models.filter { openTabIds.contains($0.key) }
    }
}

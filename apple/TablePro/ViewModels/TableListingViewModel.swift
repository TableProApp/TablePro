//
//  TableListingViewModel.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
internal final class TableListingViewModel: ObservableObject {
    @Published private(set) var state: MetadataLoadState<TableListing> = .idle

    // Outlives the tab's view, so the sort, the selection and the column widths survive a tab switch.
    let grid = HeldRowsGridAdapter(configuration: DataGridConfiguration(), sortsHeldRows: true)

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
        refreshRequests: AnyPublisher<UUID, Never> = AppEvents.shared.tabRefreshRequested.eraseToAnyPublisher()
    ) {
        self.scope = scope
        self.loader = loader
        self.metadataProvider = metadataProvider
        refreshSubscription = refreshRequests
            .filter { $0 == tabId }
            .sink { [weak self] _ in self?.reload() }
    }

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
        if case .loaded(let listing) = state {
            grid.setRows(listing.rows)
        }
    }
}

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

    func retainTabs(_ openTabIds: Set<UUID>) {
        for (tabId, model) in models where !openTabIds.contains(tabId) {
            model.cancel()
        }
        models = models.filter { openTabIds.contains($0.key) }
    }
}

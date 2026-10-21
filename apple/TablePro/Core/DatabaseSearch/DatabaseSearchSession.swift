//
//  DatabaseSearchSession.swift
//  TablePro
//

import Combine
import Foundation
import os

internal enum DatabaseSearchStep: Equatable {
    case configuring
    case searching
    case finished
}

internal enum DatabaseSearchCatalogState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

internal struct DatabaseSearchSchemaGroup: Identifiable, Equatable {
    internal let schema: String?
    internal let targets: [DatabaseSearchTarget]

    internal var id: String { schema ?? "" }
}

@MainActor
internal final class DatabaseSearchSession: ObservableObject, Identifiable {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseSearch")

    internal let id = UUID()
    internal let launch: DatabaseSearchLaunchRequest
    internal let scopeDescription: String
    internal let caseMatching: FilterCaseMatching
    private let reader: any DatabaseSearchReading

    @Published internal var options = DatabaseSearchOptions()
    @Published internal var tableFilter = ""
    @Published internal private(set) var catalogState: DatabaseSearchCatalogState = .idle
    @Published internal private(set) var targets: [DatabaseSearchTarget] = []
    @Published internal private(set) var selectedTargetIds: Set<String> = []

    @Published internal private(set) var step: DatabaseSearchStep = .configuring
    @Published internal private(set) var searchedOptions: DatabaseSearchOptions?
    @Published internal private(set) var totalCount = 0
    @Published internal private(set) var completedCount = 0
    @Published internal private(set) var currentTarget: DatabaseSearchTarget?
    @Published internal private(set) var results: [DatabaseSearchTableResult] = []
    @Published internal private(set) var wasStopped = false
    @Published internal var selectedResultId: String?

    internal private(set) var runTask: Task<Void, Never>?
    private var runGeneration = 0

    internal init(
        launch: DatabaseSearchLaunchRequest,
        scopeDescription: String,
        caseMatching: FilterCaseMatching,
        reader: any DatabaseSearchReading
    ) {
        self.launch = launch
        self.scopeDescription = scopeDescription
        self.caseMatching = caseMatching
        self.reader = reader
    }

    // MARK: - Catalog

    internal func loadTablesIfNeeded() async {
        switch catalogState {
        case .loaded, .loading:
            return
        case .idle, .failed:
            break
        }
        catalogState = .loading
        do {
            let found = try await reader.tables()
            targets = found
            selectedTargetIds = Set(found.filter(isPreselected).map(\.id))
            catalogState = .loaded
        } catch is CancellationError {
            catalogState = .idle
        } catch {
            Self.logger.warning("Search catalog unreadable: \(error.publicLogShape, privacy: .public)")
            catalogState = .failed(error.localizedDescription)
        }
    }

    private func isPreselected(_ target: DatabaseSearchTarget) -> Bool {
        guard let schema = launch.schema, !schema.isEmpty else { return true }
        return target.schema == schema
    }

    // MARK: - Scope

    internal var filteredTargets: [DatabaseSearchTarget] {
        let query = tableFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return targets }
        return targets.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    internal var schemaGroups: [DatabaseSearchSchemaGroup] {
        var order: [String?] = []
        var grouped: [String: [DatabaseSearchTarget]] = [:]
        for target in filteredTargets {
            let key = target.schema ?? ""
            if grouped[key] == nil { order.append(target.schema) }
            grouped[key, default: []].append(target)
        }
        return order.map { DatabaseSearchSchemaGroup(schema: $0, targets: grouped[$0 ?? ""] ?? []) }
    }

    internal var showsSchemas: Bool {
        targets.contains { $0.schema != nil }
    }

    internal func isSelected(_ target: DatabaseSearchTarget) -> Bool {
        selectedTargetIds.contains(target.id)
    }

    internal func setSelected(_ target: DatabaseSearchTarget, _ isSelected: Bool) {
        if isSelected {
            selectedTargetIds.insert(target.id)
        } else {
            selectedTargetIds.remove(target.id)
        }
    }

    internal func selectAllFiltered() {
        selectedTargetIds.formUnion(filteredTargets.map(\.id))
    }

    internal func deselectAllFiltered() {
        selectedTargetIds.subtract(filteredTargets.map(\.id))
    }

    internal var canSelectAllFiltered: Bool {
        filteredTargets.contains { !selectedTargetIds.contains($0.id) }
    }

    internal var canDeselectAllFiltered: Bool {
        filteredTargets.contains { selectedTargetIds.contains($0.id) }
    }

    internal var selectionSummary: String {
        String(
            format: String(localized: "%1$@ of %2$@ tables"),
            selectedTargetIds.count.formatted(.number.grouping(.automatic)),
            targets.count.formatted(.number.grouping(.automatic))
        )
    }

    internal var searchDisabledReason: String? {
        if options.trimmedTerm.isEmpty {
            return String(localized: "Enter the value to search for.")
        }
        guard catalogState == .loaded else { return nil }
        if selectedTargetIds.isEmpty {
            return String(localized: "Choose at least one table to search.")
        }
        return nil
    }

    internal var canSearch: Bool {
        catalogState == .loaded && searchDisabledReason == nil
    }

    // MARK: - Run

    internal func start() {
        guard canSearch, step != .searching else { return }
        let chosen = targets.filter { selectedTargetIds.contains($0.id) }
        let searched = options
        runTask?.cancel()
        searchedOptions = searched
        results = []
        selectedResultId = nil
        wasStopped = false
        totalCount = chosen.count
        completedCount = 0
        currentTarget = nil
        step = .searching
        runGeneration += 1
        let generation = runGeneration
        runTask = Task { [weak self] in
            await self?.run(chosen, options: searched, generation: generation)
        }
    }

    private func run(
        _ chosen: [DatabaseSearchTarget],
        options searched: DatabaseSearchOptions,
        generation: Int
    ) async {
        for target in chosen {
            guard !Task.isCancelled else { break }
            currentTarget = target
            let outcome: DatabaseSearchTableResult.Outcome
            do {
                outcome = try await reader.search(target, options: searched)
            } catch {
                // A stopped search aborts the statement in flight, which reports as that table failing.
                guard !Task.isCancelled else { break }
                Self.logger.warning("Search of a table failed: \(error.publicLogShape, privacy: .public)")
                outcome = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { break }
            results.append(DatabaseSearchTableResult(target: target, outcome: outcome))
            completedCount += 1
        }
        // Edit Search may have moved on from this run while its last read was still answering.
        guard generation == runGeneration, step == .searching else { return }
        wasStopped = completedCount < totalCount
        currentTarget = nil
        step = .finished
        if selectedResultId == nil {
            selectedResultId = matchedResults.first?.id
        }
    }

    internal func stop() {
        runTask?.cancel()
    }

    internal func editSearch() {
        runTask?.cancel()
        runGeneration += 1
        currentTarget = nil
        step = .configuring
    }

    // MARK: - Results

    internal var matchedResults: [DatabaseSearchTableResult] {
        results.filter { $0.match != nil }
    }

    internal var failedResults: [DatabaseSearchTableResult] {
        results.filter { $0.failure != nil }
    }

    internal var listedResults: [DatabaseSearchTableResult] {
        matchedResults + failedResults
    }

    internal var selectedMatch: DatabaseSearchTableResult? {
        guard let selectedResultId else { return nil }
        return results.first { $0.id == selectedResultId && $0.match != nil }
    }

    internal var progressFraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }
}

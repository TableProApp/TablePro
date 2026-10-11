//
//  VersionHistoryViewModel.swift
//  TablePro
//

import Combine
import Foundation
import os

internal struct VersionHistoryComparison: Equatable {
    let older: VersionHistoryEntry
    let newer: VersionHistoryEntry
    let outcome: VersionComparison
}

internal struct VersionHistoryDetail: Equatable {
    let entry: VersionHistoryEntry
    let content: String
    let comparison: VersionHistoryComparison?
}

@MainActor
internal final class VersionHistoryViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.TablePro", category: "VersionHistory")

    internal enum ListState: Equatable {
        case loading
        case failed(String)
        case loaded
    }

    internal enum DetailState: Equatable {
        case empty
        case loading
        case failed(String)
        case loaded(VersionHistoryDetail)
    }

    internal enum DisplayMode: Hashable {
        case changes
        case content
    }

    @Published private(set) var listState: ListState = .loading
    @Published private(set) var page: VersionHistoryPage = .empty
    @Published private(set) var detailState: DetailState = .empty
    @Published private(set) var isRestoring = false
    @Published var displayMode: DisplayMode = .changes
    @Published var diffLayout: TextDiffLayout = .split
    @Published var selection: VersionHistoryReference? {
        didSet {
            guard selection != oldValue else { return }
            loadDetail()
        }
    }

    var onRestored: () -> Void = {}
    var confirmReplacingUncommittedChanges: () async -> Bool = { true }
    var reportRestoreFailure: (String) -> Void = { _ in }

    let subject: VersionHistorySubject
    private let provider: any VersionHistoryProvider
    private var pastContentCache: [VersionHistoryReference: String] = [:]
    private var listTask: Task<Void, Never>?
    private(set) var detailTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        subject: VersionHistorySubject,
        provider: any VersionHistoryProvider,
        refreshSignal: AnyPublisher<Void, Never>
    ) {
        self.subject = subject
        self.provider = provider
        refreshSignal
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.reload() }
            .store(in: &cancellables)
    }

    var selectedEntry: VersionHistoryEntry? {
        guard let selection else { return nil }
        return page.entries.first { $0.reference == selection }
    }

    private var shownReference: VersionHistoryReference? {
        guard case .loaded(let detail) = detailState else { return nil }
        return detail.entry.reference
    }

    var canRestoreSelection: Bool {
        guard let entry = selectedEntry else { return false }
        return !entry.isCurrent && !isRestoring
    }

    func reload() {
        listTask?.cancel()
        listTask = Task { [weak self] in
            await self?.loadList()
        }
    }

    func loadList() async {
        if page.entries.isEmpty {
            listState = .loading
        }
        do {
            let loaded = try await provider.loadHistory()
            guard !Task.isCancelled else { return }
            page = loaded
            listState = .loaded
            if let selection, loaded.entries.contains(where: { $0.reference == selection }) {
                loadDetail()
            } else {
                selection = loaded.entries.first?.reference
            }
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.warning("Version history failed to load: \(error.publicLogShape, privacy: .public)")
            let subjectIsGone = (error as? VersionHistoryError) == .subjectNotFound
            guard page.entries.isEmpty || subjectIsGone else { return }
            page = .empty
            selection = nil
            detailState = .empty
            listState = .failed(error.localizedDescription)
        }
    }

    func restore(_ entry: VersionHistoryEntry) async {
        guard !entry.isCurrent, !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            let plan = try await provider.prepareRestore(entry.reference)
            if plan.replacesUncommittedChanges {
                guard await confirmReplacingUncommittedChanges() else { return }
            }
            try await plan.apply()
            onRestored()
            selection = .current
            await loadList()
        } catch {
            reportRestoreFailure(error.localizedDescription)
        }
    }

    private func loadDetail() {
        detailTask?.cancel()
        guard let entry = selectedEntry else {
            detailState = .empty
            return
        }
        if shownReference != entry.reference {
            detailState = .loading
        }
        let baseline = page.baseline(for: entry.reference)
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await content(of: entry.reference)
                let comparison = try await comparison(for: entry, content: content, baseline: baseline)
                guard !Task.isCancelled else { return }
                detailState = .loaded(VersionHistoryDetail(entry: entry, content: content, comparison: comparison))
            } catch {
                guard !Task.isCancelled else { return }
                detailState = .failed(error.localizedDescription)
            }
        }
    }

    private func comparison(
        for entry: VersionHistoryEntry,
        content: String,
        baseline: VersionHistoryEntry?
    ) async throws -> VersionHistoryComparison? {
        guard let baseline else { return nil }
        let baselineContent = try await self.content(of: baseline.reference)
        let (older, newer) = entry.isCurrent ? (baseline, entry) : (entry, baseline)
        let (olderContent, newerContent) = entry.isCurrent ? (baselineContent, content) : (content, baselineContent)
        let outcome = await Task.detached(priority: .userInitiated) {
            VersionComparison.compare(baseline: olderContent, current: newerContent)
        }.value
        return VersionHistoryComparison(older: older, newer: newer, outcome: outcome)
    }

    private func content(of reference: VersionHistoryReference) async throws -> String {
        if let cached = pastContentCache[reference] {
            return cached
        }
        let content = try await provider.content(of: reference)
        if reference != .current {
            pastContentCache[reference] = content
        }
        return content
    }
}

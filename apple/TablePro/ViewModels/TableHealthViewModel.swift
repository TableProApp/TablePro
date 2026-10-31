import Combine
import Foundation
import os

enum TableHealthError: LocalizedError {
    case noDatabase

    var errorDescription: String? {
        String(localized: "Select a database in the sidebar to check its tables.")
    }
}

@MainActor
final class TableHealthViewModel: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TableHealth")

    let provider: (any TableHealthProvider)?

    @Published private(set) var report: TableHealthReport?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var loadError: String?
    @Published var selectedFindingId: TableHealthFinding.ID?

    private let connectionId: UUID
    private let metadata: any ScopedMetadataProviding
    private var refreshTask: Task<Void, Never>?

    var isSupported: Bool { provider != nil }

    var selectedFinding: TableHealthFinding? {
        selectedFindingId.flatMap { report?.finding(id: $0) }
    }

    init(
        connectionId: UUID,
        provider: (any TableHealthProvider)?,
        metadata: any ScopedMetadataProviding = DatabaseManager.shared
    ) {
        self.connectionId = connectionId
        self.provider = provider
        self.metadata = metadata
    }

    // A pane switch restarts `.task`, so only the first appearance loads.
    func loadIfNeeded() async {
        guard report == nil, loadError == nil else { return }
        await refresh()
    }

    // The model owns the read, so a pane switch that cancels `.task` neither drops it nor leaves the
    // next appearance waiting on nothing: a second call joins the one in flight.
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        guard let provider else { return }
        let task = Task { await self.performRefresh(provider) }
        refreshTask = task
        await task.value
    }

    private func performRefresh(_ provider: any TableHealthProvider) async {
        isRefreshing = true
        defer {
            isRefreshing = false
            refreshTask = nil
        }

        do {
            guard let scope = metadata.browseScope(for: connectionId) else { throw DatabaseError.notConnected }
            guard !scope.isServerScoped else { throw TableHealthError.noDatabase }
            let fresh = try await metadata.withMetadataDriver(scope: scope, workload: .bulk) { driver in
                let context = TableHealthQueryContext(database: scope.database) { driver.quoteIdentifier($0) }
                return try await provider.fetchReport(context: context) { query in
                    try await driver.executeRead(query: query)
                }
            }
            report = Self.merging(fresh, over: report)
            loadError = nil
            lastRefreshDate = Date()
            if selectedFinding == nil { selectedFindingId = nil }
        } catch {
            Self.logger.warning("Table health refresh failed: \(error.publicLogShape, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    // A check that failed this time keeps the findings it had, shown under its new error.
    static func merging(_ fresh: TableHealthReport, over previous: TableHealthReport?) -> TableHealthReport {
        guard let previous, previous.database == fresh.database else { return fresh }
        var merged = fresh
        for index in merged.checks.indices {
            guard case .failed = merged.checks[index].outcome,
                  let prior = previous.checks.first(where: { $0.kind == merged.checks[index].kind })
            else { continue }
            merged.checks[index].findings = prior.findings
        }
        return merged
    }
}

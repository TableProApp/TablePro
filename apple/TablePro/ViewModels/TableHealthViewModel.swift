//
//  TableHealthViewModel.swift
//  TablePro
//

import Combine
import Foundation
import os

@MainActor
final class TableHealthViewModel: ObservableObject {
    typealias Execute = @MainActor (String) async throws -> QueryResult
    /// Throws when the connection has no live driver, so the report says so once instead of once per check.
    typealias ExecutorSource = @MainActor () throws -> Execute

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TableHealth")

    let databaseType: DatabaseType
    let provider: TableHealthProvider?

    @Published private(set) var report: TableHealthReport?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var loadError: String?
    @Published var selectedFindingId: TableHealthFinding.ID?

    private let executorSource: ExecutorSource

    var isSupported: Bool { provider != nil }

    var selectedFinding: TableHealthFinding? {
        guard let selectedFindingId, let report else { return nil }
        for check in report.checks {
            if let finding = check.findings.first(where: { $0.id == selectedFindingId }) {
                return finding
            }
        }
        return nil
    }

    init(
        databaseType: DatabaseType,
        provider: TableHealthProvider?,
        executorSource: @escaping ExecutorSource
    ) {
        self.databaseType = databaseType
        self.provider = provider
        self.executorSource = executorSource
    }

    convenience init(connectionId: UUID, databaseType: DatabaseType, services: AppServices = .live) {
        self.init(
            databaseType: databaseType,
            provider: TableHealthProviderFactory.provider(for: databaseType),
            executorSource: {
                guard services.databaseManager.driver(for: connectionId) != nil else {
                    throw DatabaseError.connectionFailed(String(localized: "No active connection"))
                }
                return { query in
                    guard let driver = services.databaseManager.driver(for: connectionId) else {
                        throw DatabaseError.connectionFailed(String(localized: "No active connection"))
                    }
                    return try await driver.executeRead(query: query)
                }
            }
        )
    }

    /// A pane switch re-runs `.task`, so only the first appearance loads.
    func loadIfNeeded() async {
        guard report == nil, loadError == nil else { return }
        await refresh()
    }

    func refresh() async {
        guard let provider, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let execute = try executorSource()
            let fresh = try await provider.fetchReport(execute: execute)
            report = Self.merging(fresh, over: report)
            loadError = nil
            lastRefreshDate = Date()
            if selectedFinding == nil { selectedFindingId = nil }
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning("Table health refresh failed: \(error.publicLogShape, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    /// A check that failed this time keeps the findings it had, shown under its new error.
    static func merging(_ fresh: TableHealthReport, over previous: TableHealthReport?) -> TableHealthReport {
        guard let previous else { return fresh }
        var merged = fresh
        for index in merged.checks.indices where merged.checks[index].error != nil {
            if let prior = previous.checks.first(where: { $0.kind == merged.checks[index].kind }) {
                merged.checks[index].findings = prior.findings
            }
        }
        if merged.statisticsNote == nil {
            merged.statisticsNote = previous.statisticsNote
        }
        return merged
    }
}

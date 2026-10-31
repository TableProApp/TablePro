//
//  TableHealthViewModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct TableHealthViewModelTests {
    private struct Offline: LocalizedError {
        var errorDescription: String? { "No active connection" }
    }

    /// Answers the missing primary key check with the given tables and every other check with nothing.
    @MainActor
    private final class FakeServer {
        var tablesWithoutKey: [String] = ["logs"]
        var isOnline = true
        private(set) var queryCount = 0

        func executorSource() throws -> TableHealthViewModel.Execute {
            guard isOnline else { throw Offline() }
            return { [self] query in
                queryCount += 1
                guard query == PostgreSQLTableHealthProvider.missingPrimaryKeyQuery else {
                    return TableHealthFixture.result(columns: [], rows: [])
                }
                return TableHealthFixture.result(
                    columns: ["schema_name", "table_name"],
                    rows: tablesWithoutKey.map { table -> [String?] in ["public", table] }
                )
            }
        }
    }

    private func makeViewModel(_ server: FakeServer, databaseType: DatabaseType = .postgresql) -> TableHealthViewModel {
        TableHealthViewModel(
            databaseType: databaseType,
            provider: TableHealthProviderFactory.provider(for: databaseType),
            executorSource: { try server.executorSource() }
        )
    }

    @Test("An engine without a provider is not supported and runs nothing")
    func unsupportedEngine() async {
        let server = FakeServer()
        let viewModel = makeViewModel(server, databaseType: .sqlite)

        await viewModel.refresh()

        #expect(!viewModel.isSupported)
        #expect(viewModel.report == nil)
        #expect(server.queryCount == 0)
    }

    @Test("The first appearance loads and a second appearance does not reload")
    func loadsOnce() async {
        let server = FakeServer()
        let viewModel = makeViewModel(server)

        await viewModel.loadIfNeeded()
        let afterFirst = server.queryCount
        await viewModel.loadIfNeeded()

        #expect(viewModel.report?.findingCount == 1)
        #expect(afterFirst > 0)
        #expect(server.queryCount == afterFirst)
    }

    @Test("A lost connection says so once, and a later refresh clears it")
    func offlineThenOnline() async {
        let server = FakeServer()
        server.isOnline = false
        let viewModel = makeViewModel(server)

        await viewModel.refresh()
        #expect(viewModel.loadError == "No active connection")
        #expect(viewModel.report == nil)

        server.isOnline = true
        await viewModel.refresh()
        #expect(viewModel.loadError == nil)
        #expect(viewModel.report?.findingCount == 1)
    }

    @Test("A failed refresh keeps the report it already had")
    func failedRefreshKeepsReport() async {
        let server = FakeServer()
        let viewModel = makeViewModel(server)
        await viewModel.refresh()

        server.isOnline = false
        await viewModel.refresh()

        #expect(viewModel.report?.findingCount == 1)
        #expect(viewModel.loadError != nil)
    }

    @Test("A refresh drops the selection when its finding is gone and keeps it otherwise")
    func selectionFollowsFindings() async throws {
        let server = FakeServer()
        server.tablesWithoutKey = ["logs", "events"]
        let viewModel = makeViewModel(server)
        await viewModel.refresh()

        let report = try #require(viewModel.report)
        let events = try #require(report.checks.flatMap { $0.findings }.first { $0.table == "events" })
        viewModel.selectedFindingId = events.id

        await viewModel.refresh()
        #expect(viewModel.selectedFinding?.table == "events")

        server.tablesWithoutKey = ["logs"]
        await viewModel.refresh()
        #expect(viewModel.selectedFindingId == nil)
        #expect(viewModel.selectedFinding == nil)
    }
}

//
//  DashboardTileBoardTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct DashboardTileBoardTests {
    private static let queued = "SELECT count(*) FROM jobs WHERE state = 'queued'"

    @MainActor
    private final class Fixture {
        let suite: EphemeralDefaults
        let connectionId = UUID()
        let changes = PassthroughSubject<UUID?, Never>()
        var catalog: DashboardSavedQueryCatalog
        var executed: [String] = []
        var answer: (String) throws -> QueryResult = { _ in Fixture.result(columns: ["count"], rows: [["12"]]) }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var gate: any ExecutionGate = AlwaysAllowGate()
        var holdExecution: AsyncGate?
        var loads = 0
        var safeModeLevel = SafeModeLevel.silent

        init(favorites: [SQLFavorite]) throws {
            suite = try EphemeralDefaults()
            catalog = DashboardSavedQueryCatalog(favorites: favorites, folders: [])
        }

        var storage: ServerDashboardTileStorage {
            let defaults = suite.defaults
            return ServerDashboardTileStorage(defaults: { defaults })
        }

        func makeBoard(databaseType: DatabaseType = .postgresql, chartsAvailable: Bool = true) -> DashboardTileBoard {
            let environment = DashboardTileBoard.Environment(
                loadCatalog: { _ in
                    self.loads += 1
                    return self.catalog
                },
                savedQueriesDidChange: changes.eraseToAnyPublisher(),
                gate: gate,
                forcesWrite: { _ in false },
                safeModeLevel: { _ in self.safeModeLevel },
                chartsAvailable: { chartsAvailable },
                nullDisplay: { "NULL" },
                storage: storage,
                now: { self.clock }
            )
            return DashboardTileBoard(
                connectionId: connectionId,
                databaseType: databaseType,
                environment: environment
            ) { sql in
                self.executed.append(sql)
                if let hold = self.holdExecution {
                    await hold.wait()
                }
                return try self.answer(sql)
            }
        }

        nonisolated static func result(columns: [String], types: [ColumnType]? = nil, rows: [[PluginCellValue]]) -> QueryResult {
            QueryResult(
                columns: columns,
                columnTypes: types ?? columns.map { _ in .integer(rawType: "bigint") },
                rows: rows,
                rowsAffected: 0,
                executionTime: 0,
                error: nil
            )
        }
    }

    private actor CountingGate: ExecutionGate {
        private(set) var requests: [OperationRequest] = []

        func authorize(_ request: OperationRequest) async -> OperationDecision {
            requests.append(request)
            return await AlwaysAllowGate().authorize(request)
        }
    }

    private struct QueryFailed: LocalizedError {
        var errorDescription: String? { "relation \"jobs\" does not exist" }
    }

    private func favorite(_ query: String = queued, name: String = "Queued jobs") -> SQLFavorite {
        SQLFavorite(name: name, query: query)
    }

    @Test("A saved count shows as a value tile, and the tile is there again on the next launch")
    func valueTileSurvivesRelaunch() async throws {
        let saved = favorite()
        let fixture = try Fixture(favorites: [saved])
        let board = fixture.makeBoard()

        board.add(favoriteId: saved.id)
        let tile = try #require(board.tiles.first)
        try await waitUntil { board.state(for: tile.id).display != nil }

        #expect(board.state(for: tile.id).display == .value("12"))
        #expect(fixture.executed == [Self.queued])

        let relaunched = fixture.makeBoard()
        #expect(relaunched.tiles == board.tiles)
        await relaunched.refresh(force: false)
        #expect(relaunched.state(for: tile.id).display == .value("12"))
    }

    @Test("A saved query that writes is refused with the reason and never runs")
    func writeIsRefused() async throws {
        let saved = favorite("UPDATE jobs SET state = 'done'")
        let fixture = try Fixture(favorites: [saved])
        let gate = CountingGate()
        fixture.gate = gate
        let board = fixture.makeBoard()
        board.add(favoriteId: saved.id)
        let tile = try #require(board.tiles.first)

        try await waitUntil { board.state(for: tile.id).refusal != nil }
        await board.refresh(force: true)

        #expect(board.state(for: tile.id).refusal == String(localized: "This saved query is not a read. Tiles run reads only."))
        #expect(board.state(for: tile.id).display == nil)
        #expect(fixture.executed.isEmpty)
        #expect(await gate.requests.isEmpty)
    }

    @Test("A gate refusal is shown on the tile and the query never runs")
    func gateDenialIsShown() async throws {
        let saved = favorite()
        let fixture = try Fixture(favorites: [saved])
        fixture.gate = AlwaysDenyGate(reason: "Confirmation is required for this operation")
        let board = fixture.makeBoard()
        board.add(favoriteId: saved.id)
        let tile = try #require(board.tiles.first)

        try await waitUntil { board.state(for: tile.id).refusal != nil }

        #expect(board.state(for: tile.id).refusal == "Confirmation is required for this operation")
        #expect(fixture.executed.isEmpty)
    }

    @Test("The gate decides once per statement, not per refresh; Refresh Now and a Safe Mode change ask again")
    func gateIsAskedOncePerStatement() async throws {
        let saved = favorite()
        let fixture = try Fixture(favorites: [saved])
        let gate = CountingGate()
        fixture.gate = gate
        let board = fixture.makeBoard()
        board.add(favoriteId: saved.id)
        let tile = try #require(board.tiles.first)
        try await waitUntil { board.state(for: tile.id).display != nil }

        await board.refresh(force: false)
        await board.refresh(force: false)
        #expect(fixture.executed.count == 3)
        #expect(await gate.requests.count == 1)

        let request = try #require(await gate.requests.first)
        #expect(request.kind == .readQuery)
        #expect(request.capabilities == [.cannotPrompt])
        #expect(request.sql == Self.queued)

        await board.refresh(force: true)
        #expect(await gate.requests.count == 2)

        fixture.safeModeLevel = .alertFull
        await board.refresh(force: false)
        #expect(await gate.requests.count == 3)
    }

    @Test("A slower tile waits for its interval, and Refresh Now runs it anyway")
    func slowerIntervalWaits() async throws {
        let saved = favorite()
        let fixture = try Fixture(favorites: [saved])
        let board = fixture.makeBoard()
        board.add(favoriteId: saved.id)
        let tile = try #require(board.tiles.first)
        try await waitUntil { board.state(for: tile.id).display != nil }
        board.setInterval(.fiveMinutes, for: tile.id)

        fixture.clock.addTimeInterval(30)
        await board.refresh(force: false)
        #expect(fixture.executed.count == 1)

        await board.refresh(force: true)
        #expect(fixture.executed.count == 2)

        fixture.clock.addTimeInterval(299)
        await board.refresh(force: false)
        #expect(fixture.executed.count == 3)
        #expect(fixture.makeBoard().tiles.first?.interval == .fiveMinutes)
    }

    @Test("A failed run keeps the last result on the tile and shows the error")
    func failureKeepsLastResult() async throws {
        let saved = favorite()
        let fixture = try Fixture(favorites: [saved])
        let board = fixture.makeBoard()
        board.add(favoriteId: saved.id)
        let tile = try #require(board.tiles.first)
        try await waitUntil { board.state(for: tile.id).display != nil }

        fixture.answer = { _ in throw QueryFailed() }
        await board.refresh(force: true)

        #expect(board.state(for: tile.id).display == .value("12"))
        #expect(board.state(for: tile.id).error == "relation \"jobs\" does not exist")
    }

    @Test("A run cancelled by leaving the dashboard records nothing and stays due")
    func cancelledRunStaysDue() async throws {
        let saved = favorite()
        let fixture = try Fixture(favorites: [saved])
        let tile = DashboardTile(favoriteId: saved.id, interval: .oneHour)
        fixture.storage.save(ServerDashboardTileLayout(tiles: [tile]), for: fixture.connectionId)
        fixture.answer = { _ in throw CancellationError() }
        let board = fixture.makeBoard()

        await board.run(tile.id)

        let state = board.state(for: tile.id)
        #expect(state.error == nil)
        #expect(state.lastRun == nil)
        #expect(!state.isRunning)
        #expect(tile.interval.isDue(lastRun: state.lastRun, now: fixture.clock))
    }

    @Test("Editing the saved query runs the tile again on the new text")
    func editedSavedQueryRunsAgain() async throws {
        var saved = favorite()
        let fixture = try Fixture(favorites: [saved])
        let board = fixture.makeBoard()
        board.isActive = true
        board.add(favoriteId: saved.id)
        let tile = try #require(board.tiles.first)
        try await waitUntil { board.state(for: tile.id).display != nil }

        saved.query = "SELECT count(*) FROM jobs WHERE state = 'failed'"
        fixture.catalog = DashboardSavedQueryCatalog(favorites: [saved], folders: [])
        fixture.answer = { _ in Fixture.result(columns: ["count"], rows: [["3"]]) }
        fixture.changes.send(nil)

        try await waitUntil { board.state(for: tile.id).display == .value("3") }
        #expect(fixture.executed.last == saved.query)
    }

    @Test("An edit while the dashboard is paused, Off or hidden waits for the next cycle")
    func editWhilePausedWaits() async throws {
        var saved = favorite()
        let fixture = try Fixture(favorites: [saved])
        let board = fixture.makeBoard()
        board.add(favoriteId: saved.id)
        let tile = try #require(board.tiles.first)
        try await waitUntil { board.state(for: tile.id).display != nil }
        board.setInterval(.oneHour, for: tile.id)

        saved.query = "SELECT count(*) FROM jobs WHERE state = 'failed'"
        fixture.catalog = DashboardSavedQueryCatalog(favorites: [saved], folders: [])
        fixture.changes.send(fixture.connectionId)
        try await waitUntil { board.savedQuery(for: tile)?.query == saved.query }
        #expect(fixture.executed == [Self.queued])

        await board.refresh(force: false)
        #expect(fixture.executed == [Self.queued, saved.query])
    }

    @Test("Pause, Off and leaving the dashboard all stop edit reruns")
    func dashboardStateDrivesTileActivity() {
        let viewModel = ServerDashboardViewModel(connectionId: UUID(), databaseType: .mysql, services: .live)
        viewModel.refreshInterval = .off
        viewModel.startAutoRefresh()
        #expect(!viewModel.tileBoard.isActive)
        viewModel.refreshInterval = .fiveSeconds
        #expect(viewModel.tileBoard.isActive)
        viewModel.isPaused = true
        #expect(!viewModel.tileBoard.isActive)
        viewModel.isPaused = false
        #expect(viewModel.tileBoard.isActive)
        viewModel.stopAutoRefresh()
        #expect(!viewModel.tileBoard.isActive)
    }

    @Test("A change announced for another connection is ignored")
    func otherConnectionChangeIgnored() async throws {
        var saved = favorite()
        let fixture = try Fixture(favorites: [saved])
        let board = fixture.makeBoard()
        board.isActive = true
        board.add(favoriteId: saved.id)
        let tile = try #require(board.tiles.first)
        try await waitUntil { board.state(for: tile.id).display != nil }

        let loadsBefore = fixture.loads
        saved.query = "SELECT 1"
        fixture.catalog = DashboardSavedQueryCatalog(favorites: [saved], folders: [])
        fixture.changes.send(UUID())
        fixture.changes.send(fixture.connectionId)

        try await waitUntil { board.savedQuery(for: tile)?.query == "SELECT 1" }
        #expect(fixture.loads == loadsBefore + 1)
    }

    @Test("A result that lands after its tile was removed is dropped")
    func lateResultForRemovedTileIsDropped() async throws {
        let saved = favorite()
        let fixture = try Fixture(favorites: [saved])
        let tile = DashboardTile(favoriteId: saved.id)
        fixture.storage.save(ServerDashboardTileLayout(tiles: [tile]), for: fixture.connectionId)
        let hold = AsyncGate()
        fixture.holdExecution = hold
        let board = fixture.makeBoard()

        async let running: Void = board.run(tile.id)
        await hold.arrived(1)
        board.remove(tile.id)
        await hold.open()
        await running

        #expect(fixture.executed == [Self.queued])
        #expect(board.states[tile.id] == nil)
        #expect(board.tiles.isEmpty)
        #expect(fixture.makeBoard().tiles.isEmpty)
    }

    @Test("A tile whose saved query was deleted says so")
    func deletedSavedQuery() async throws {
        let fixture = try Fixture(favorites: [])
        let board = fixture.makeBoard()
        board.add(favoriteId: UUID())
        let tile = try #require(board.tiles.first)

        try await waitUntil { board.state(for: tile.id).refusal != nil }

        #expect(board.title(for: tile) == String(localized: "Saved Query"))
        #expect(fixture.executed.isEmpty)
    }

    @Test("A dropped tile takes the target's place from either side, and the order persists")
    func reorder() async throws {
        let favorites = [favorite(name: "A"), favorite(name: "B"), favorite(name: "C")]
        let fixture = try Fixture(favorites: favorites)
        let board = fixture.makeBoard()
        favorites.forEach { board.add(favoriteId: $0.id) }
        let ids = board.tiles.map { $0.id }

        board.move(ids[0], onto: ids[2])
        #expect(board.tiles.map { $0.id } == [ids[1], ids[2], ids[0]])

        board.move(ids[0], onto: ids[1])
        #expect(board.tiles.map { $0.id } == ids)

        board.moveLater(ids[1])
        #expect(board.tiles.map { $0.id } == [ids[0], ids[2], ids[1]])
        board.moveEarlier(ids[0])
        #expect(board.tiles.map { $0.id } == [ids[0], ids[2], ids[1]])

        #expect(fixture.makeBoard().tiles.map { $0.id } == [ids[0], ids[2], ids[1]])
    }

    @Test("A saved query already on the dashboard is not added twice")
    func noDuplicateTiles() async throws {
        let saved = favorite()
        let fixture = try Fixture(favorites: [saved])
        let board = fixture.makeBoard()
        board.add(favoriteId: saved.id)
        board.add(favoriteId: saved.id)
        #expect(board.tiles.count == 1)
    }

    @Test("A fetch that stopped at the tile's cap says more rows exist")
    func cappedFetchIsMarked() async throws {
        let saved = favorite("SELECT id, state FROM jobs")
        let fixture = try Fixture(favorites: [saved])
        fixture.answer = { _ in
            var result = Fixture.result(
                columns: ["id", "state"],
                rows: (0 ..< DashboardTileTable.rowCap).map { [.text("\($0)"), .text("queued")] }
            )
            result.isTruncated = true
            return result
        }
        let board = fixture.makeBoard()
        board.add(favoriteId: saved.id)
        let tile = try #require(board.tiles.first)
        try await waitUntil { board.state(for: tile.id).display != nil }

        guard case .table(let table) = board.state(for: tile.id).display else {
            Issue.record("Expected a table")
            return
        }
        #expect(table.isTruncated)
        #expect(table.rows.count == DashboardTileTable.maximumRowCount)
        #expect(table.totalRowCount == DashboardTileTable.rowCap)
    }

    @Test("A series over time draws a line, and without the chart license shows a table")
    func lineChartFollowsTheLicense() async throws {
        let saved = favorite("SELECT date_trunc('hour', created_at) AS hour, count(*) FROM jobs GROUP BY 1")
        let rows: [[PluginCellValue]] = [["2026-10-21 10:00:00", "4"], ["2026-10-21 11:00:00", "9"]]
        let types: [ColumnType] = [.timestamp(rawType: "timestamp"), .integer(rawType: "bigint")]

        for chartsAvailable in [true, false] {
            let fixture = try Fixture(favorites: [saved])
            fixture.answer = { _ in Fixture.result(columns: ["hour", "count"], types: types, rows: rows) }
            let board = fixture.makeBoard(chartsAvailable: chartsAvailable)
            board.add(favoriteId: saved.id)
            let tile = try #require(board.tiles.first)
            try await waitUntil { board.state(for: tile.id).display != nil }

            switch board.state(for: tile.id).display {
            case .lineChart(let projection, let isTruncated):
                #expect(chartsAvailable)
                #expect(!isTruncated)
                #expect(projection.points.count == 2)
            case .table(let table):
                #expect(!chartsAvailable)
                #expect(table.rows.count == 2)
            default:
                Issue.record("Expected a chart or a table")
            }
        }
    }
}

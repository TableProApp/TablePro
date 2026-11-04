//
//  DashboardTileBoard.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

@MainActor
final class DashboardTileBoard: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ServerDashboardTiles")

    struct TileState: Equatable {
        var display: DashboardTileDisplay?
        var error: String?
        var refusal: String?
        var lastRun: Date?
        var isRunning = false
    }

    typealias Execute = @MainActor (String) async throws -> QueryResult

    struct Environment {
        var loadCatalog: @MainActor (UUID) async -> DashboardSavedQueryCatalog
        var savedQueriesDidChange: AnyPublisher<UUID?, Never>
        var gate: any ExecutionGate
        var forcesWrite: @MainActor (DatabaseType) -> Bool
        var safeModeLevel: @MainActor (UUID) -> SafeModeLevel
        var chartsAvailable: @MainActor () -> Bool
        var nullDisplay: @MainActor () -> String
        var storage: ServerDashboardTileStorage
        var now: @MainActor () -> Date = Date.init

        @MainActor
        static func live(services: AppServices) -> Environment {
            let savedQueries = services.sqlFavoriteManager
            return Environment(
                loadCatalog: { connectionId in
                    async let favorites = savedQueries.fetchFavorites(connectionId: connectionId)
                    async let folders = savedQueries.fetchFolders(connectionId: connectionId)
                    return await DashboardSavedQueryCatalog(favorites: favorites, folders: folders)
                },
                savedQueriesDidChange: services.appEvents.sqlFavoritesDidUpdate.eraseToAnyPublisher(),
                gate: ExecutionGateProvider.shared,
                forcesWrite: { databaseType in
                    ExecutionGateProvider.forcesWrite(
                        databaseType,
                        supportsReadOnlyMode: services.pluginManager.supportsReadOnlyMode(for: databaseType)
                    )
                },
                safeModeLevel: { connectionId in
                    let connectionLevel: SafeModeLevel
                    switch services.databaseManager.connectionState(connectionId) {
                    case .live(_, let session): connectionLevel = session.safeModeLevel
                    case .stored(let connection): connectionLevel = connection.safeModeLevel
                    case .unknown: connectionLevel = .silent
                    }
                    return ManagedPolicyResolver.effectiveSafeModeLevel(
                        connectionLevel: connectionLevel,
                        policy: ManagedPolicyReader.shared
                    )
                },
                chartsAvailable: { services.featureAccess.isAvailable(.resultCharts) },
                nullDisplay: { services.appSettings.dataGrid.nullDisplay },
                storage: ServerDashboardTileStorage()
            )
        }
    }

    let connectionId: UUID
    let databaseType: DatabaseType

    @Published private(set) var tiles: [DashboardTile]
    @Published private(set) var states: [UUID: TileState] = [:]
    @Published private(set) var catalog: DashboardSavedQueryCatalog = .empty

    /// False while the dashboard is off screen, paused or Off: an edited saved query then waits for the cycle.
    var isActive = false

    private let environment: Environment
    private let execute: Execute
    private var hasLoadedCatalog = false
    private var catalogLoad: Task<Void, Never>?
    private struct GateDecision {
        let sql: String
        let safeModeLevel: SafeModeLevel
        let denial: String?
    }

    /// One gate decision per tile, statement and Safe Mode level, until Refresh Now. The gate logs
    /// every decision, and a tile on a one second cycle must not append one each second.
    private var gateDecisions: [UUID: GateDecision] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(connectionId: UUID, databaseType: DatabaseType, environment: Environment, execute: @escaping Execute) {
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.environment = environment
        self.execute = execute
        tiles = environment.storage.load(for: connectionId).tiles

        environment.savedQueriesDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] changedConnectionId in
                guard let self else { return }
                guard changedConnectionId == nil || changedConnectionId == self.connectionId else { return }
                Task { await self.savedQueriesDidChange() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Reading

    func savedQuery(for tile: DashboardTile) -> SQLFavorite? {
        catalog.favorite(id: tile.favoriteId)
    }

    func title(for tile: DashboardTile) -> String {
        savedQuery(for: tile)?.name ?? String(localized: "Saved Query")
    }

    func state(for tileId: UUID) -> TileState {
        states[tileId] ?? TileState()
    }

    func contains(favoriteId: UUID) -> Bool {
        tiles.contains { $0.favoriteId == favoriteId }
    }

    // MARK: - Layout

    func add(favoriteId: UUID) {
        guard !contains(favoriteId: favoriteId) else { return }
        let tile = DashboardTile(favoriteId: favoriteId)
        tiles.append(tile)
        save()
        Task { await self.run(tile.id) }
    }

    func remove(_ tileId: UUID) {
        tiles.removeAll { $0.id == tileId }
        states[tileId] = nil
        gateDecisions[tileId] = nil
        save()
    }

    /// The moved tile takes the target's place, from either side.
    func move(_ tileId: UUID, onto targetId: UUID) {
        guard let from = tiles.firstIndex(where: { $0.id == tileId }),
              let to = tiles.firstIndex(where: { $0.id == targetId }),
              from != to
        else { return }
        var reordered = tiles
        reordered.insert(reordered.remove(at: from), at: to)
        tiles = reordered
        save()
    }

    func moveEarlier(_ tileId: UUID) {
        guard let index = tiles.firstIndex(where: { $0.id == tileId }), index > 0 else { return }
        move(tileId, onto: tiles[index - 1].id)
    }

    func moveLater(_ tileId: UUID) {
        guard let index = tiles.firstIndex(where: { $0.id == tileId }), index < tiles.count - 1 else { return }
        move(tileId, onto: tiles[index + 1].id)
    }

    func setInterval(_ interval: DashboardTileInterval, for tileId: UUID) {
        guard let index = tiles.firstIndex(where: { $0.id == tileId }), tiles[index].interval != interval else { return }
        tiles[index].interval = interval
        save()
    }

    private func save() {
        environment.storage.save(ServerDashboardTileLayout(tiles: tiles), for: connectionId)
    }

    // MARK: - Running

    /// `force` is Refresh Now: every tile runs, due or not, and the gate is asked again.
    func refresh(force: Bool) async {
        if force {
            gateDecisions.removeAll()
        }
        await loadCatalogIfNeeded()
        let now = environment.now()
        for tile in tiles where force || tile.interval.isDue(lastRun: state(for: tile.id).lastRun, now: now) {
            guard !Task.isCancelled else { return }
            await run(tile.id)
        }
    }

    func loadCatalogIfNeeded() async {
        guard !hasLoadedCatalog else { return }
        if let catalogLoad {
            await catalogLoad.value
            return
        }
        await reloadCatalog()
    }

    /// Loads run one after another, so a read started before an edit cannot land after the one
    /// started by it.
    func reloadCatalog() async {
        let previous = catalogLoad
        let load = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let loaded = await self.environment.loadCatalog(self.connectionId)
            self.catalog = loaded
            self.hasLoadedCatalog = true
        }
        catalogLoad = load
        await load.value
    }

    private func savedQueriesDidChange() async {
        let before = Dictionary(tiles.map { ($0.id, savedQuery(for: $0)?.query) }, uniquingKeysWith: { first, _ in first })
        let wasLoaded = hasLoadedCatalog
        await reloadCatalog()
        guard wasLoaded else { return }
        for tile in tiles where savedQuery(for: tile)?.query != (before[tile.id] ?? nil) {
            gateDecisions[tile.id] = nil
            states[tile.id]?.lastRun = nil
            if isActive {
                await run(tile.id)
            }
        }
    }

    func run(_ tileId: UUID) async {
        guard tiles.contains(where: { $0.id == tileId }), !state(for: tileId).isRunning else { return }
        states[tileId, default: TileState()].isRunning = true
        await loadCatalogIfNeeded()
        guard let tile = tiles.first(where: { $0.id == tileId }) else { return }
        guard let sql = savedQuery(for: tile)?.query else {
            refuse(tileId, String(localized: "This saved query was deleted or belongs to another connection."))
            return
        }
        if let refusal = DashboardTilePolicy.refusal(
            for: sql,
            databaseType: databaseType,
            forcesWrite: environment.forcesWrite(databaseType)
        ) {
            refuse(tileId, refusal)
            return
        }

        let startedAt = environment.now()

        let denial: String?
        let safeModeLevel = environment.safeModeLevel(connectionId)
        if let cached = gateDecisions[tileId], cached.sql == sql, cached.safeModeLevel == safeModeLevel {
            denial = cached.denial
        } else {
            let decision = await environment.gate.authorize(request(for: sql))
            guard isCurrent(tileId, sql: sql) else {
                finishStale(tileId)
                return
            }
            denial = decision.deniedReason
            gateDecisions[tileId] = GateDecision(sql: sql, safeModeLevel: safeModeLevel, denial: denial)
        }
        if let denial {
            refuse(tileId, denial)
            return
        }

        do {
            let result = try await execute(sql)
            if let error = result.error {
                throw error
            }
            let display = try await makeDisplay(result)
            guard isCurrent(tileId, sql: sql) else {
                finishStale(tileId)
                return
            }
            states[tileId] = TileState(display: display, error: nil, refusal: nil, lastRun: startedAt, isRunning: false)
        } catch {
            // Leaving the dashboard cancels the cycle; the tile has not run, so it stays due.
            if error is CancellationError || Task.isCancelled {
                if tiles.contains(where: { $0.id == tileId }) {
                    states[tileId]?.isRunning = false
                }
                return
            }
            guard isCurrent(tileId, sql: sql) else {
                finishStale(tileId)
                return
            }
            Self.logger.warning("Dashboard tile query failed: \(error.publicLogShape, privacy: .public)")
            var state = state(for: tileId)
            state.error = error.localizedDescription
            state.refusal = nil
            state.lastRun = startedAt
            state.isRunning = false
            states[tileId] = state
        }
    }

    private func refuse(_ tileId: UUID, _ reason: String) {
        guard tiles.contains(where: { $0.id == tileId }) else { return }
        states[tileId] = TileState(display: nil, error: nil, refusal: reason, lastRun: environment.now(), isRunning: false)
    }

    /// The tile was removed, or its saved query changed, while the statement ran. The answer belongs
    /// to neither, so it is dropped, and a changed query runs again on its own text.
    private func finishStale(_ tileId: UUID) {
        guard tiles.contains(where: { $0.id == tileId }) else { return }
        states[tileId]?.isRunning = false
        states[tileId]?.lastRun = nil
        if isActive {
            Task { await self.run(tileId) }
        }
    }

    private func isCurrent(_ tileId: UUID, sql: String) -> Bool {
        guard let tile = tiles.first(where: { $0.id == tileId }) else { return false }
        return savedQuery(for: tile)?.query == sql
    }

    private func request(for sql: String) -> OperationRequest {
        OperationRequest(
            connectionId: connectionId,
            databaseType: databaseType,
            sql: sql,
            kind: .readQuery,
            caller: .userInterface,
            capabilities: [.cannotPrompt],
            operationDescription: String(localized: "Run a saved query on the Server Dashboard")
        )
    }

    private func makeDisplay(_ result: QueryResult) async throws(CancellationError) -> DashboardTileDisplay {
        let nullDisplay = environment.nullDisplay()
        let header = TableRows(columns: result.columns, columnTypes: result.columnTypes)
        let shape = DashboardTileShape.of(
            columns: ResultChartColumn.columns(in: header),
            rowCount: result.rows.count,
            chartsAvailable: environment.chartsAvailable()
        )
        let table = DashboardTileDisplay.table(
            DashboardTileTable(
                columns: result.columns,
                rows: result.rows,
                isTruncated: result.isTruncated,
                nullDisplay: nullDisplay
            )
        )
        switch shape {
        case .value:
            let cell = result.rows.first?.first ?? .null
            return .value(DashboardTileTable.text(cell, nullDisplay: nullDisplay))
        case .table:
            return table
        case .lineChart(let configuration):
            let tableRows = TableRows.from(
                queryRows: result.rows,
                columns: result.columns,
                columnTypes: result.columnTypes
            )
            let projection = try await ResultChartProjector.shared.project(
                tableRows: tableRows,
                configuration: configuration
            )
            guard !projection.points.isEmpty else { return table }
            return .lineChart(projection, isTruncated: result.isTruncated)
        }
    }
}

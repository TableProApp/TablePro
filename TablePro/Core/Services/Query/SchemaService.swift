//
//  SchemaService.swift
//  TablePro
//

import Foundation
import os

@MainActor
@Observable
final class SchemaService {
    static let shared = SchemaService()

    private(set) var states: [UUID: SchemaState] = [:]

    @ObservationIgnored private var lastLoadDates: [UUID: Date] = [:]
    @ObservationIgnored private let loadDedup = OnceTask<UUID, [TableInfo]>()
    @ObservationIgnored private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaService")

    init() {}

    func state(for connectionId: UUID) -> SchemaState {
        states[connectionId] ?? .idle
    }

    func tables(for connectionId: UUID) -> [TableInfo] {
        if case .loaded(let tables) = state(for: connectionId) {
            return tables
        }
        return []
    }

    func load(connectionId: UUID, driver: DatabaseDriver, connection: DatabaseConnection) async {
        switch state(for: connectionId) {
        case .loaded:
            return
        case .idle, .loading, .failed:
            await runLoad(connectionId: connectionId, driver: driver, connection: connection)
        }
    }

    func reload(connectionId: UUID, driver: DatabaseDriver, connection: DatabaseConnection) async {
        await runLoad(connectionId: connectionId, driver: driver, connection: connection)
    }

    func reloadIfStale(
        connectionId: UUID,
        driver: DatabaseDriver,
        connection: DatabaseConnection,
        staleness: TimeInterval
    ) async {
        guard let lastLoad = lastLoadDates[connectionId] else {
            await reload(connectionId: connectionId, driver: driver, connection: connection)
            return
        }
        guard Date().timeIntervalSince(lastLoad) > staleness else { return }
        await reload(connectionId: connectionId, driver: driver, connection: connection)
    }

    func invalidate(connectionId: UUID) async {
        await loadDedup.cancel(key: connectionId)
        states.removeValue(forKey: connectionId)
        lastLoadDates.removeValue(forKey: connectionId)
    }

    private func runLoad(
        connectionId: UUID,
        driver: DatabaseDriver,
        connection: DatabaseConnection
    ) async {
        states[connectionId] = .loading
        do {
            let tables = try await loadDedup.execute(key: connectionId) {
                try await driver.fetchTables()
            }
            states[connectionId] = .loaded(tables)
            lastLoadDates[connectionId] = Date()
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] load failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            states[connectionId] = .failed(error.localizedDescription)
        }
    }
}

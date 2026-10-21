//
//  ServerDashboardTileStorage.swift
//  TablePro
//

import Foundation
import os

struct ServerDashboardTileStorage: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ServerDashboardTileStorage")

    private let defaults: @Sendable () -> UserDefaults

    init(defaults: @escaping @Sendable () -> UserDefaults = { AppStorageEnvironment.shared.defaults }) {
        self.defaults = defaults
    }

    static func key(for connectionId: UUID) -> String {
        "ServerDashboardTiles.\(connectionId.uuidString)"
    }

    func load(for connectionId: UUID) -> ServerDashboardTileLayout {
        guard let data = defaults().data(forKey: Self.key(for: connectionId)) else { return .empty }
        do {
            return try JSONDecoder().decode(ServerDashboardTileLayout.self, from: data)
        } catch {
            Self.logger.error("Failed to decode dashboard tiles: \(error.publicLogShape, privacy: .public)")
            return .empty
        }
    }

    func save(_ layout: ServerDashboardTileLayout, for connectionId: UUID) {
        guard !layout.tiles.isEmpty else {
            remove(for: connectionId)
            return
        }
        do {
            defaults().set(try JSONEncoder().encode(layout), forKey: Self.key(for: connectionId))
        } catch {
            Self.logger.error("Failed to encode dashboard tiles: \(error.publicLogShape, privacy: .public)")
        }
    }

    func remove(for connectionId: UUID) {
        defaults().removeObject(forKey: Self.key(for: connectionId))
    }
}

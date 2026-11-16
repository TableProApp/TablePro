//
//  ServerDashboardTileStorage.swift
//  TablePro
//

import Foundation

struct ServerDashboardTileStorage: Sendable {
    private let defaults: @Sendable () -> UserDefaults

    init(defaults: @escaping @Sendable () -> UserDefaults = { AppStorageEnvironment.shared.defaults }) {
        self.defaults = defaults
    }

    static func key(for connectionId: UUID) -> String {
        "ServerDashboardTiles.\(connectionId.uuidString)"
    }

    private static func entry(for connectionId: UUID) -> JSONDefaultsKey<ServerDashboardTileLayout> {
        JSONDefaultsKey(key(for: connectionId))
    }

    func load(for connectionId: UUID) -> ServerDashboardTileLayout {
        defaults().read(Self.entry(for: connectionId)).value ?? .empty
    }

    func save(_ layout: ServerDashboardTileLayout, for connectionId: UUID) {
        guard !layout.tiles.isEmpty else {
            remove(for: connectionId)
            return
        }
        try? defaults().write(layout, to: Self.entry(for: connectionId))
    }

    func remove(for connectionId: UUID) {
        defaults().removeValue(for: Self.entry(for: connectionId))
    }
}

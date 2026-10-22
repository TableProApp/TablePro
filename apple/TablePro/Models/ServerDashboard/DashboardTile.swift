//
//  DashboardTile.swift
//  TablePro
//

import Foundation

struct DashboardTile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let favoriteId: UUID
    var interval: DashboardTileInterval

    init(id: UUID = UUID(), favoriteId: UUID, interval: DashboardTileInterval = .dashboard) {
        self.id = id
        self.favoriteId = favoriteId
        self.interval = interval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        favoriteId = try container.decode(UUID.self, forKey: .favoriteId)
        // A value a newer build added must not drop the whole layout.
        let seconds = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 0
        interval = DashboardTileInterval(rawValue: seconds) ?? .dashboard
    }
}

/// Only ever slower than the dashboard: an expensive count should not run every second.
enum DashboardTileInterval: Int, Codable, CaseIterable, Identifiable, Sendable {
    case dashboard = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3_600

    var id: Int { rawValue }

    var displayLabel: String {
        switch self {
        case .dashboard: return String(localized: "With the Dashboard")
        case .oneMinute: return String(localized: "Every Minute")
        case .fiveMinutes: return String(localized: "Every 5 Minutes")
        case .fifteenMinutes: return String(localized: "Every 15 Minutes")
        case .oneHour: return String(localized: "Every Hour")
        }
    }

    func isDue(lastRun: Date?, now: Date) -> Bool {
        guard self != .dashboard, let lastRun else { return true }
        // The cycle sleeps after its work, so a tick can land a little short of a whole minute.
        return now.timeIntervalSince(lastRun) >= TimeInterval(rawValue) - 1
    }
}

struct ServerDashboardTileLayout: Codable, Equatable, Sendable {
    var tiles: [DashboardTile]

    static let empty = ServerDashboardTileLayout(tiles: [])

    init(tiles: [DashboardTile]) {
        self.tiles = tiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tiles = try container.decodeIfPresent([DashboardTile].self, forKey: .tiles) ?? []
    }
}

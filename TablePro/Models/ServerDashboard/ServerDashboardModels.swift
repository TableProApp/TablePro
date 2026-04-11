//
//  ServerDashboardModels.swift
//  TablePro
//

import Foundation

// MARK: - Dashboard Panel

enum DashboardPanel: Hashable {
    case activeSessions
    case serverMetrics
    case slowQueries
}

// MARK: - Refresh Interval

enum DashboardRefreshInterval: Double, CaseIterable, Identifiable {
    case off = 0
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30

    var id: Double { rawValue }

    var displayLabel: String {
        switch self {
        case .off: return String(localized: "Off")
        default: return "\(Int(rawValue))s"
        }
    }
}

// MARK: - Dashboard Session

struct DashboardSession: Identifiable {
    let id: String
    let user: String
    let database: String
    let state: String
    let durationSeconds: Int
    let duration: String
    let query: String
    var canKill: Bool = true
    var canCancel: Bool = true
}

// MARK: - Dashboard Metric

struct DashboardMetric: Identifiable {
    let id: String
    let label: String
    let value: String
    let unit: String
    let icon: String
}

// MARK: - Dashboard Slow Query

struct DashboardSlowQuery: Identifiable {
    let id = UUID()
    let duration: String
    let query: String
    let user: String
    let database: String
}

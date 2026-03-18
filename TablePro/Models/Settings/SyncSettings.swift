//
//  SyncSettings.swift
//  TablePro
//
//  User-configurable sync preferences
//

import Foundation

/// User preferences for iCloud sync behavior
struct SyncSettings: Codable, Equatable {
    var enabled: Bool
    var syncConnections: Bool
    var syncGroupsAndTags: Bool
    var syncSettings: Bool
    var syncQueryHistory: Bool
    var historySyncLimit: HistorySyncLimit

    static let `default` = SyncSettings(
        enabled: false,
        syncConnections: true,
        syncGroupsAndTags: true,
        syncSettings: true,
        syncQueryHistory: true,
        historySyncLimit: .entries500
    )
}

/// Maximum number of query history entries to sync
enum HistorySyncLimit: String, Codable, CaseIterable {
    case entries100 = "100"
    case entries500 = "500"
    case entries1000 = "1000"
    case unlimited = "unlimited"

    var displayName: String {
        switch self {
        case .entries100: return "100"
        case .entries500: return "500"
        case .entries1000: return "1,000"
        case .unlimited: return String(localized: "Unlimited")
        }
    }

    var limit: Int? {
        switch self {
        case .entries100: return 100
        case .entries500: return 500
        case .entries1000: return 1_000
        case .unlimited: return nil
        }
    }
}

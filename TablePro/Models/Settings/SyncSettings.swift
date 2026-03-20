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
    var syncPasswords: Bool
    var syncSSHProfiles: Bool

    init(
        enabled: Bool,
        syncConnections: Bool,
        syncGroupsAndTags: Bool,
        syncSettings: Bool,
        syncQueryHistory: Bool,
        historySyncLimit: HistorySyncLimit,
        syncPasswords: Bool = false,
        syncSSHProfiles: Bool = true
    ) {
        self.enabled = enabled
        self.syncConnections = syncConnections
        self.syncGroupsAndTags = syncGroupsAndTags
        self.syncSettings = syncSettings
        self.syncQueryHistory = syncQueryHistory
        self.historySyncLimit = historySyncLimit
        self.syncPasswords = syncPasswords
        self.syncSSHProfiles = syncSSHProfiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        syncConnections = try container.decode(Bool.self, forKey: .syncConnections)
        syncGroupsAndTags = try container.decode(Bool.self, forKey: .syncGroupsAndTags)
        syncSettings = try container.decode(Bool.self, forKey: .syncSettings)
        syncQueryHistory = try container.decode(Bool.self, forKey: .syncQueryHistory)
        historySyncLimit = try container.decode(HistorySyncLimit.self, forKey: .historySyncLimit)
        syncPasswords = try container.decodeIfPresent(Bool.self, forKey: .syncPasswords) ?? false
        syncSSHProfiles = try container.decodeIfPresent(Bool.self, forKey: .syncSSHProfiles) ?? true
    }

    static let `default` = SyncSettings(
        enabled: false,
        syncConnections: true,
        syncGroupsAndTags: true,
        syncSettings: true,
        syncQueryHistory: true,
        historySyncLimit: .entries500,
        syncPasswords: false,
        syncSSHProfiles: true
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

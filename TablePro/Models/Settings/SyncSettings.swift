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
    var syncPasswords: Bool
    var syncSSHProfiles: Bool

    init(
        enabled: Bool,
        syncConnections: Bool,
        syncGroupsAndTags: Bool,
        syncSettings: Bool,
        syncPasswords: Bool = false,
        syncSSHProfiles: Bool = true
    ) {
        self.enabled = enabled
        self.syncConnections = syncConnections
        self.syncGroupsAndTags = syncGroupsAndTags
        self.syncSettings = syncSettings
        self.syncPasswords = syncPasswords
        self.syncSSHProfiles = syncSSHProfiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        syncConnections = try container.decode(Bool.self, forKey: .syncConnections)
        syncGroupsAndTags = try container.decode(Bool.self, forKey: .syncGroupsAndTags)
        syncSettings = try container.decode(Bool.self, forKey: .syncSettings)
        syncPasswords = try container.decodeIfPresent(Bool.self, forKey: .syncPasswords) ?? false
        syncSSHProfiles = try container.decodeIfPresent(Bool.self, forKey: .syncSSHProfiles) ?? true
    }

    static let `default` = SyncSettings(
        enabled: false,
        syncConnections: true,
        syncGroupsAndTags: true,
        syncSettings: true,
        syncPasswords: false,
        syncSSHProfiles: true
    )
}

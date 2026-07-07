//
//  ProFeature.swift
//  TablePro
//
//  Pro feature definitions and access control types
//

import Foundation

/// Features that require a Pro (active) license
internal enum ProFeature: String, CaseIterable {
    case iCloudSync
    case encryptedExport
    case envVarReferences
    case linkedFolders
    case teamCatalog

    var displayName: String {
        switch self {
        case .iCloudSync:
            return String(localized: "iCloud Sync")
        case .encryptedExport:
            return String(localized: "Encrypted Export")
        case .envVarReferences:
            return String(localized: "Environment Variables")
        case .linkedFolders:
            return String(localized: "Linked Folders")
        case .teamCatalog:
            return String(localized: "Team Catalog")
        }
    }

    var systemImage: String {
        switch self {
        case .iCloudSync:
            return "icloud"
        case .encryptedExport:
            return "lock.doc"
        case .envVarReferences:
            return "dollarsign.square"
        case .linkedFolders:
            return "folder.badge.gearshape"
        case .teamCatalog:
            return "person.2.fill"
        }
    }

    var featureDescription: String {
        switch self {
        case .iCloudSync:
            return String(localized: "Sync connections, settings, and history across your Macs.")
        case .encryptedExport:
            return String(localized: "Export connections with encrypted credentials.")
        case .envVarReferences:
            return String(localized: "Use environment variables in connection fields.")
        case .linkedFolders:
            return String(localized: "Watch shared folders for connection files.")
        case .teamCatalog:
            return String(localized: "Publish connections to a shared folder your team reads from. Passwords are never included.")
        }
    }

    /// The lowest license tier that unlocks this feature.
    var requiredTier: LicenseTier {
        switch self {
        case .iCloudSync, .encryptedExport, .envVarReferences, .linkedFolders:
            return .starter
        case .teamCatalog:
            return .team
        }
    }
}

/// Result of checking Pro feature availability
internal enum ProFeatureAccess: Equatable {
    case available
    case unlicensed
    case expired
    case validationFailed
    case requiresUpgrade(LicenseTier)
}

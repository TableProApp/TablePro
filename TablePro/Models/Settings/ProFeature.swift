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
        }
    }
}

/// Result of checking Pro feature availability
internal enum ProFeatureAccess {
    case available
    case unlicensed
    case expired
    case validationFailed
}

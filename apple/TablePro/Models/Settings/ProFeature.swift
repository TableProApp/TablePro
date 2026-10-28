//
//  ProFeature.swift
//  TablePro
//

import Foundation

// Raw values are the feature codes the entitlement carries (product.md, Feature codes).
internal enum ProFeature: String, CaseIterable {
    case iCloudSync = "icloud_sync"
    case encryptedExport = "encrypted_export"
    case envVarReferences = "env_var_references"
    case linkedFolders = "linked_folders"
    case queryInsights = "query_insights"
    case resultCharts = "result_charts"
    case teamCatalog = "team_catalog"
    case teamLibrary = "team_library"
    case compareSync = "compare_sync"
    case dataRewind = "data_rewind"

    var displayName: String {
        switch self {
        case .queryInsights:
            return String(localized: "Query Insights")
        case .resultCharts:
            return String(localized: "Result Charts")
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
        case .teamLibrary:
            return String(localized: "Team Library")
        case .compareSync:
            return String(localized: "Compare & Sync")
        case .dataRewind:
            return String(localized: "Data Rewind")
        }
    }

    var systemImage: String {
        switch self {
        case .queryInsights:
            return "chart.bar.xaxis"
        case .resultCharts:
            return "chart.xyaxis.line"
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
        case .teamLibrary:
            return "books.vertical.fill"
        case .compareSync:
            return "arrow.left.arrow.right.square"
        case .dataRewind:
            return "clock.arrow.circlepath"
        }
    }

    var featureDescription: String {
        switch self {
        case .queryInsights:
            return String(localized: "See which queries you run most, which run slowest, and which got slower.")
        case .resultCharts:
            return String(localized: "Turn loaded query results into native bar, line, area, and scatter charts.")
        case .iCloudSync:
            return String(localized: "Sync connections, settings, and favorites across your Macs.")
        case .encryptedExport:
            return String(localized: "Export connections with encrypted credentials.")
        case .envVarReferences:
            return String(localized: "Use environment variables in connection fields.")
        case .linkedFolders:
            return String(localized: "Watch shared folders for connection files.")
        case .teamCatalog:
            return String(localized: "Publish connections to a shared folder your team reads from. Passwords are never included.")
        case .teamLibrary:
            return String(localized: "Share connections and saved queries with your team through your account. Passwords are never included.")
        case .compareSync:
            return String(localized: "Compare structure or data between two connections and generate the sync script.")
        case .dataRewind:
            return String(localized: "Restore the previous values of rows you already saved.")
        }
    }

    // Which plan includes a feature is the server's to say (GET /v2/pricing), so this names none.
    var paidPlanRequirement: String {
        String(format: String(localized: "%@ needs a paid plan"), displayName)
    }
}

internal enum ProFeatureAccess: Equatable {
    case available
    case signedOut
    case notIncluded
    case expired
    case refreshFailed
}

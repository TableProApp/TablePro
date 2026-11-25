//
//  SyncCoordinator+Rules.swift
//  TablePro
//

import Foundation
import TableProSyncTransport

// Rules that read nothing but their arguments, and the cache the coordinator starts with.
extension SyncCoordinator {
    nonisolated static func makeRecordCache() -> SyncRecordCache {
        SyncRecordCache(
            directory: AppStorageEnvironment.shared.supportDirectory
                .appendingPathComponent("SyncRecordCache", isDirectory: true),
            defaults: AppStorageEnvironment.shared.defaults
        )
    }

    // Exhaustive, so a paying customer the app could not reach the server about is never told to buy.
    nonisolated static func licenseDisableReason(for access: ProFeatureAccess) -> DisableReason? {
        switch access {
        case .available:
            return nil
        case .expired:
            return .licenseExpired
        case .refreshFailed:
            return .licenseUnverified
        case .signedOut, .notIncluded:
            return .licenseRequired
        }
    }

    nonisolated static func isTokenExpired(_ error: Error) -> Bool {
        SyncFailure(error) == .tokenExpired
    }

    // Groups and tags write only their own store, and the rest are collected and applied after the loop.
    static func leavesConnectionLibraryAlone(_ type: SyncRecordType) -> Bool {
        switch type {
        case .connection, .group, .tag, .tableFavorite, .tableFolder, .tableFolderItem, .favorite, .favoriteFolder:
            return true
        case .settings, .sshProfile, .credentialProfile, .favoriteDatabase:
            return false
        }
    }

    static func availableProfileName(
        basedOn name: String,
        taken profiles: [CredentialProfile]
    ) -> String {
        let used = Set(profiles.map { $0.name.lowercased() })
        for index in 2...99 {
            let candidate = String(format: String(localized: "%1$@ (%2$lld)"), name, Int64(index))
            if !used.contains(candidate.lowercased()) { return candidate }
        }
        return name
    }
}

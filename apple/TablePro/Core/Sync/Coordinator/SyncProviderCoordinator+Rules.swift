//
//  SyncProviderCoordinator+Rules.swift
//  TablePro
//

import Foundation
import TableProFFI
import TableProSyncTransport

// The Mac's rules that read nothing but their arguments, and the record cache the Swift engine left.
extension SyncProviderCoordinator {
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

    // The kinds this Mac's switches leave out, and whether passwords ride along.
    nonisolated static func categories(_ settings: SyncSettings) -> SyncCategoriesArg {
        SyncCategoriesArg(
            offKinds: SyncRecordType.allCases.filter { !settings.syncs($0) }.map(\.coreKind),
            passwords: settings.syncsPasswords
        )
    }
}

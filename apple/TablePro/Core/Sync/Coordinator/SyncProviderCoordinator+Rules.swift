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

    // The kinds this Mac's switches leave out, and whether passwords ride along. A connection project groups connections,
    // so it goes with them. Only TablePro Sync carries envelopes, so its own Passwords switch decides, whatever provider
    // the engine is opened for: a move to it plans the passwords it will seal (core ADR 0054, Moving between providers).
    nonisolated static func categories(_ settings: SyncSettings) -> SyncCategoriesArg {
        var off = SyncRecordType.allCases
            .filter { !settings.syncs($0) }
            .map(\.coreKind)
        if !settings.syncConnections, !off.contains(connectionProjectKind) {
            off.append(connectionProjectKind)
        }
        return SyncCategoriesArg(
            offKinds: off,
            passwords: settings.syncConnections && settings.syncPasswordsOnTableProSync
        )
    }

    nonisolated static let connectionProjectKind = SyncRecordType.project.coreKind
}

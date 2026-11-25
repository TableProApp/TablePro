//
//  SyncProviderCoordinator+Rules.swift
//  TablePro
//

import Foundation
import TableProFFI
import TableProSyncTransport

// Rules that read nothing but their arguments, and the record cache the Swift engine left.
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

    // The engine's status while iCloud runs on this Mac. An engine still reading the provider off is about to run it.
    nonisolated static func status(_ info: SyncStatusInfo) -> SyncStatus {
        switch info.phase {
        case .syncing:
            return .syncing
        case .zoneRemoved:
            return .error(.blocked(.dataDeletedFromICloud))
        case .waiting:
            return .error(info.problem.map(error(forProblem:)) ?? .busy)
        case .off, .idle, .pullOnly, .newIdentity, .unavailable:
            return info.problem.map { .error(error(forProblem: $0)) } ?? .idle
        }
    }

    // The last pass's error code (core `SyncError::code`), in the terms the person can act on.
    nonisolated static func error(forProblem code: String) -> SyncError {
        switch code {
        case "sync.icloud.no_account":
            return .blocked(.signedOut)
        case "sync.icloud.restricted":
            return .blocked(.accountRestricted)
        case "sync.icloud.account_temporarily_unavailable":
            return .blocked(.accountNotReady)
        case "sync.icloud.quota_exceeded":
            return .blocked(.storageFull)
        case "sync.icloud.zone_deleted_by_user", "sync.icloud.zone_not_found":
            return .blocked(.dataDeletedFromICloud)
        case "sync.icloud.network":
            return .offline
        case "sync.icloud.throttled", "sync.state.busy":
            return .busy
        case "sync.adapter.store":
            return .pullNotSaved
        // A contract the engine's lanes have not filled yet.
        case "sync.unimplemented":
            return .blocked(.unavailable)
        default:
            return .unexpected
        }
    }

    // A pass the person asked for runs whatever held the last one back, so it stands in for any other.
    nonisolated static func stronger(_ pending: PassReasonTag?, _ incoming: PassReasonTag) -> PassReasonTag {
        guard let pending else { return incoming }
        return rank(incoming) > rank(pending) ? incoming : pending
    }

    nonisolated private static func rank(_ reason: PassReasonTag) -> Int {
        switch reason {
        case .foreground: return 0
        case .networkBack: return 1
        case .cloudKitPush: return 2
        case .launch: return 3
        case .person: return 4
        }
    }
}

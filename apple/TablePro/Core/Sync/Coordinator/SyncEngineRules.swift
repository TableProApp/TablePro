//
//  SyncEngineRules.swift
//  TablePro
//

import Foundation
import TableProFFI
import TableProSyncTransport

// What the core engine's status, problem codes and pass reasons mean to the person (core ADR 0054). The Mac and the
// iPhone app both compile it, so each shows the same condition for the same engine state.
nonisolated enum SyncEngineRules {
    // The engine's status while iCloud runs on this device. Only the engine's own phase says the zone was removed, which
    // is what offers Upload Again. An engine still reading the provider off is about to run it.
    static func status(_ info: SyncStatusInfo) -> SyncStatus {
        switch info.phase {
        case .syncing:
            return .syncing
        case .zoneRemoved:
            return .error(.blocked(.dataDeletedFromICloud))
        case .waiting:
            return .error(info.problem.flatMap(error(forProblem:)) ?? .busy)
        case .unavailable:
            return .error(info.problem.flatMap(error(forProblem:)) ?? .blocked(.unavailable))
        // `pullOnly` is TablePro Sync's. On iCloud, `newIdentity` holds the push after an account switch until the person
        // picks Move my data or Start empty (core ADR 0066), a choice neither app has a sheet for yet.
        case .pullOnly, .newIdentity:
            return .error(.unexpected)
        case .off, .idle:
            return info.problem.flatMap(error(forProblem:)).map { .error($0) } ?? .idle
        }
    }

    // The last pass's error code (core `SyncError::code`), in the terms the person can act on. Nil for a pass that only
    // gave way: the account changed or the pass was cancelled, and the next one reports.
    static func error(forProblem code: String) -> SyncError? {
        switch code {
        case "sync.icloud.no_account":
            return .blocked(.signedOut)
        case "sync.icloud.restricted":
            return .blocked(.accountRestricted)
        case "sync.icloud.account_temporarily_unavailable":
            return .blocked(.accountNotReady)
        case "sync.icloud.quota_exceeded":
            return .blocked(.storageFull)
        case "sync.icloud.network":
            return .offline
        case "sync.icloud.throttled", "sync.state.busy":
            return .busy
        // The keychain holds the state file's anchor; the core starts the engine again once it answers.
        case "sync.state.anchor_unsettled", "sync.device_store.locked":
            return .waitingForKeychain
        case "sync.adapter.store":
            return .pullNotSaved
        case "sync.icloud.account_changed", "sync.cancelled":
            return nil
        // A contract the engine's lanes have not filled yet.
        case "sync.unimplemented":
            return .blocked(.unavailable)
        default:
            return .unexpected
        }
    }

    // A pass the person asked for runs whatever held the last one back, so it stands in for any other.
    static func stronger(_ pending: PassReasonTag?, _ incoming: PassReasonTag) -> PassReasonTag {
        guard let pending else { return incoming }
        return rank(incoming) > rank(pending) ? incoming : pending
    }

    // A pass that reads more stands in for one that reads less: launch and an account change read the account and the
    // zone again, a CloudKit notice names changes waiting, and a journal pass only sends what this device wrote.
    private static func rank(_ reason: PassReasonTag) -> Int {
        switch reason {
        case .journal: return 0
        case .foreground: return 1
        case .networkBack: return 2
        case .cloudKitPush: return 3
        case .accountChanged: return 4
        case .launch: return 5
        case .person: return 6
        }
    }
}

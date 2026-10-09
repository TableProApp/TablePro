import Foundation
import Testing

import TableProSyncTransport

@Suite("Sync admission")
struct SyncAdmissionTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private var later: Date { now.addingTimeInterval(300) }
    private var earlier: Date { now.addingTimeInterval(-1) }

    private static let everyTrigger: [SyncTrigger] = [
        .launch, .activation, .localChange, .accountChange, .networkRestored, .scheduledRetry, .userRequest
    ]

    @Test("Nothing in the way admits every trigger", arguments: everyTrigger)
    func cleanStateAdmitsAll(_ trigger: SyncTrigger) {
        #expect(SyncAdmission.decide(for: trigger, after: nil, nextAttempt: nil, now: now) == .full)
        #expect(SyncAdmission.decide(for: trigger, after: .recordsRejected(count: 1), nextAttempt: nil, now: now) == .full)
        #expect(SyncAdmission.decide(for: trigger, after: .offline, nextAttempt: nil, now: now) == .full)
    }

    /// The reported bug: every edit and activation resent all 250 pending changes to a full iCloud.
    @Test("Full storage keeps edits from uploading before the wait is over")
    func storageFullHoldsEdits() {
        let error = SyncError.blocked(.storageFull)
        #expect(SyncAdmission.decide(for: .localChange, after: error, nextAttempt: later, now: now) == .none)
        #expect(SyncAdmission.decide(for: .activation, after: error, nextAttempt: later, now: now) == .downloadOnly)
        #expect(SyncAdmission.decide(for: .networkRestored, after: error, nextAttempt: later, now: now) == .downloadOnly)
    }

    @Test("Full storage lets the person, the timer and an account change try the upload")
    func storageFullAdmitsDeliberateTriggers() {
        let error = SyncError.blocked(.storageFull)
        for trigger in [SyncTrigger.userRequest, .scheduledRetry, .accountChange, .launch] {
            #expect(SyncAdmission.decide(for: trigger, after: error, nextAttempt: later, now: now) == .full)
        }
    }

    @Test("Full storage admits every trigger once the wait is over")
    func storageFullAfterWait() {
        let error = SyncError.blocked(.storageFull)
        for trigger in Self.everyTrigger {
            #expect(SyncAdmission.decide(for: trigger, after: error, nextAttempt: earlier, now: now) == .full)
        }
    }

    @Test("An account blocker ignores edits and lets everything else look at the account again",
          arguments: [SyncBlocker.signedOut, .accountNotReady, .accountRestricted])
    func accountBlockers(_ blocker: SyncBlocker) {
        let error = SyncError.blocked(blocker)
        #expect(SyncAdmission.decide(for: .localChange, after: error, nextAttempt: nil, now: now) == .none)
        for trigger in [SyncTrigger.launch, .activation, .accountChange, .userRequest] {
            #expect(SyncAdmission.decide(for: trigger, after: error, nextAttempt: nil, now: now) == .full)
        }
    }

    /// Apple asks apps not to resend data removed from iCloud on their own, so nothing uploads; a
    /// download still looks for a zone another device may have brought back.
    @Test("Deleted iCloud data never uploads on a trigger, and only looks for the zone")
    func deletedDataWaitsForChoice() {
        let error = SyncError.blocked(.dataDeletedFromICloud)
        #expect(SyncAdmission.decide(for: .localChange, after: error, nextAttempt: nil, now: now) == .none)
        for trigger in Self.everyTrigger where trigger != .localChange {
            #expect(SyncAdmission.decide(for: trigger, after: error, nextAttempt: nil, now: now) == .downloadOnly)
        }
    }

    @Test("A build or version fault is tried again only at launch or on request",
          arguments: [SyncBlocker.appUpdateRequired, .unavailable])
    func buildFaults(_ blocker: SyncBlocker) {
        let error = SyncError.blocked(blocker)
        for trigger in Self.everyTrigger {
            let expected: SyncAdmission = trigger == .launch || trigger == .userRequest ? .full : .none
            #expect(SyncAdmission.decide(for: trigger, after: error, nextAttempt: nil, now: now) == expected)
        }
    }

    @Test("A throttle holds automatic triggers until its wait is over")
    func busyHoldsUntilDue() {
        #expect(SyncAdmission.decide(for: .activation, after: .busy, nextAttempt: later, now: now) == .none)
        #expect(SyncAdmission.decide(for: .userRequest, after: .busy, nextAttempt: later, now: now) == .full)
        #expect(SyncAdmission.decide(for: .activation, after: .busy, nextAttempt: earlier, now: now) == .full)
    }
}

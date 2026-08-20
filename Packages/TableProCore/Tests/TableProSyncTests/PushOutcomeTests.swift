import CloudKit
import Foundation
import Testing

@testable import TableProSyncTransport

@Suite("Push outcome accounting")
struct PushOutcomeTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func makeRecord(_ name: String) -> CKRecord {
        CKRecord(recordType: "Connection", recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    }

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    @Test("A saved record is reported saved")
    func savedRecordIsReported() {
        var outcome = PushOutcome()
        let record = makeRecord("Connection_A")

        outcome.recordSave(record)

        #expect(outcome.didSave(record.recordID))
        #expect(outcome.hasFailures == false)
    }

    @Test("One rejected record leaves the others reported as saved")
    func oneRejectionDoesNotPoisonTheBatch() {
        var outcome = PushOutcome()
        let saved = makeRecord("Connection_A")
        let rejected = recordID("Connection_B")

        outcome.recordSave(saved)
        outcome.recordFailure(
            SyncItemFailure(code: .invalidArguments, serverRecord: nil, clientRecord: nil, message: "unknown field"),
            for: rejected
        )

        #expect(outcome.didSave(saved.recordID))
        #expect(outcome.didSave(rejected) == false)
        #expect(outcome.failures.count == 1)
    }

    @Test("Per-item errors from a partial failure are absorbed")
    func partialErrorsAreAbsorbed() {
        var outcome = PushOutcome()
        let rejected = recordID("Connection_B")
        let partial = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [rejected: CKError(.invalidArguments)]]
        )

        outcome.absorbPartialErrors(from: partial)

        #expect(outcome.failures[rejected]?.code == .invalidArguments)
    }

    @Test("A per-item conflict is separated from an outright rejection")
    func conflictsAreSeparatedFromRejections() {
        var outcome = PushOutcome()
        let conflicted = recordID("Connection_A")
        let rejected = recordID("Connection_B")

        outcome.recordFailure(
            SyncItemFailure(code: .serverRecordChanged, serverRecord: nil, clientRecord: nil, message: "changed"),
            for: conflicted
        )
        outcome.recordFailure(
            SyncItemFailure(code: .invalidArguments, serverRecord: nil, clientRecord: nil, message: "unknown field"),
            for: rejected
        )

        #expect(outcome.conflicts.keys.contains(conflicted))
        #expect(outcome.conflicts.keys.contains(rejected) == false)
        #expect(outcome.failures.count == 2)
    }

    @Test("A record that saved is never also reported as failed")
    func saveWinsOverAStaleFailure() {
        var outcome = PushOutcome()
        let record = makeRecord("Connection_A")

        outcome.recordSave(record)
        outcome.recordFailure(
            SyncItemFailure(code: .invalidArguments, serverRecord: nil, clientRecord: nil, message: "late"),
            for: record.recordID
        )

        #expect(outcome.didSave(record.recordID))
        #expect(outcome.failures.isEmpty)
    }

    @Test("A confirmed deletion is reported separately from a save")
    func deletionsAreReported() {
        var outcome = PushOutcome()
        let deleted = recordID("Connection_C")

        outcome.recordDeletion(deleted)

        #expect(outcome.didDelete(deleted))
        #expect(outcome.didSave(deleted) == false)
    }

    @Test("Merging batches keeps every saved record and every failure")
    func mergeKeepsAllResults() {
        var first = PushOutcome()
        first.recordSave(makeRecord("Connection_A"))

        var second = PushOutcome()
        second.recordSave(makeRecord("Connection_B"))
        second.recordFailure(
            SyncItemFailure(code: .invalidArguments, serverRecord: nil, clientRecord: nil, message: "unknown field"),
            for: recordID("Connection_C")
        )

        first.merge(second)

        #expect(first.savedRecords.count == 2)
        #expect(first.failures.count == 1)
    }
}

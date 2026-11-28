//
//  SyncApprovalsModelTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport
import Testing

@MainActor
struct SyncApprovalsModelTests {
    private final class Writes {
        var reads = 0
    }

    private static func model(
        _ engine: FakeSyncApprovalEngine?,
        changes: PassthroughSubject<Void, Never> = PassthroughSubject(),
        writes: Writes = Writes()
    ) -> SyncApprovalsModel {
        SyncApprovalsModel(
            engine: { engine },
            changes: changes.eraseToAnyPublisher(),
            readCoreWrites: { writes.reads += 1 }
        )
    }

    @Test("A refresh shows each waiting record and the engine's count of them")
    func refreshShowsRecords() async {
        let records = [SyncApprovalFixture.newConnection(), SyncApprovalFixture.changedConnection()]
        let engine = FakeSyncApprovalEngine(records)
        let model = Self.model(engine)

        await model.refresh()

        #expect(model.waiting == 2)
        #expect(model.records == records)
    }

    @Test("Nothing waiting reads no list, and an engine not open yet shows nothing")
    func nothingWaitingReadsNothing() async {
        let engine = FakeSyncApprovalEngine()
        let model = Self.model(engine)

        await model.refresh()

        #expect(model.waiting == 0)
        #expect(model.records.isEmpty)
        #expect(engine.reads == 0)

        let closed = Self.model(nil)
        await closed.refresh()
        #expect(closed.waiting == 0)
    }

    @Test("A change signal reads the queue again, so a pull that adds a record shows it without a reopen")
    func signalRefreshes() async throws {
        let engine = FakeSyncApprovalEngine()
        let changes = PassthroughSubject<Void, Never>()
        let model = Self.model(engine, changes: changes)
        model.start()
        await model.refresh()
        #expect(model.waiting == 0)

        engine.set([SyncApprovalFixture.newConnection()])
        changes.send()

        try await waitUntil { model.waiting == 1 && model.records.count == 1 }
    }

    @Test("The count shows before the list is read, and the list is not taken as read until it is")
    func countBeforeList() async throws {
        let engine = FakeSyncApprovalEngine([SyncApprovalFixture.newConnection()])
        let model = Self.model(engine)
        let gate = AsyncGate()
        engine.holdNextRead(at: gate)

        let reading = Task { await model.refresh() }
        await gate.arrived(1)

        #expect(model.waiting == 1)
        #expect(!model.hasRead)
        await gate.open()
        await reading.value
        #expect(model.hasRead)
        #expect(model.records.count == 1)
    }

    @Test("A first read that fails says so, and never reads as nothing waiting")
    func failedFirstRead() async {
        let engine = FakeSyncApprovalEngine([SyncApprovalFixture.newConnection()])
        engine.failReads(with: SyncApprovalFixture.failure("sync.state.busy"))
        let model = Self.model(engine)

        await model.refresh()

        #expect(model.waiting == 1)
        #expect(model.readFailed)
        #expect(!model.hasRead)

        engine.failReads(with: nil)
        await model.refresh()
        #expect(!model.readFailed)
        #expect(model.hasRead)
        #expect(model.records.count == 1)
    }

    @Test("A failed read keeps the records already shown")
    func failedReadKeepsRecords() async {
        let records = [SyncApprovalFixture.changedConnection()]
        let engine = FakeSyncApprovalEngine(records)
        let model = Self.model(engine)
        await model.refresh()

        engine.failReads(with: SyncApprovalFixture.failure("sync.state.busy"))
        await model.refresh()

        #expect(model.records == records)
        #expect(model.waiting == 1)
        #expect(model.readFailed)
    }

    @Test("Approve sends the record's digest, reads the core's writes back, and the record leaves the list")
    func approveOne() async {
        let new = SyncApprovalFixture.newConnection()
        let changed = SyncApprovalFixture.changedConnection()
        let engine = FakeSyncApprovalEngine([new, changed])
        let writes = Writes()
        let model = Self.model(engine, writes: writes)
        await model.refresh()

        await model.decide(new, approve: true)

        #expect(engine.decided == ["\(SyncApprovalFixture.newID) approve"])
        #expect(writes.reads == 1)
        #expect(model.records == [changed])
        #expect(model.waiting == 1)
        #expect(model.failure == nil)
        #expect(!model.isDeciding)
    }

    @Test("Don't Apply refuses the record, which leaves the list as an approval does")
    func rejectOne() async {
        let changed = SyncApprovalFixture.changedConnection()
        let engine = FakeSyncApprovalEngine([changed])
        let model = Self.model(engine)
        await model.refresh()

        await model.decide(changed, approve: false)

        #expect(engine.decided == ["\(SyncApprovalFixture.changedID) reject"])
        #expect(model.records.isEmpty)
        #expect(model.waiting == 0)
    }

    @Test("A record a pull changed since it was shown is not decided: the new values show, with a note on that record")
    func changedSinceShown() async {
        let shown = SyncApprovalFixture.newConnection()
        let engine = FakeSyncApprovalEngine([shown])
        let model = Self.model(engine)
        await model.refresh()
        let pulledAgain = SyncApprovalFixture.newConnection(host: "db2.example.com")
        engine.set([pulledAgain])

        await model.decide(shown, approve: true)

        #expect(engine.decided.isEmpty)
        #expect(model.records == [pulledAgain])
        #expect(model.failure == SyncApprovalFailure(record: shown.record, message: SyncApprovalsModel.changedAgainMessage))
    }

    @Test("A record another window decided first counts as settled, with no failure")
    func settledElsewhere() async {
        let shown = SyncApprovalFixture.changedConnection()
        let engine = FakeSyncApprovalEngine([shown])
        let model = Self.model(engine)
        await model.refresh()
        engine.set([])

        await model.decide(shown, approve: true)

        #expect(model.failure == nil)
        #expect(model.records.isEmpty)
    }

    @Test("A decision the engine refuses for another reason keeps the record and says so")
    func decisionFails() async {
        let shown = SyncApprovalFixture.changedConnection()
        let engine = FakeSyncApprovalEngine([shown])
        engine.failDecision(on: SyncApprovalFixture.changedID, with: SyncApprovalFixture.failure("sync.state.busy"))
        let model = Self.model(engine)
        await model.refresh()

        await model.decide(shown, approve: true)

        #expect(model.records == [shown])
        #expect(model.failure == SyncApprovalFailure(record: shown.record, message: SyncApprovalsModel.saveFailedMessage))
    }

    @Test("Approve All decides every record in order, one at a time")
    func approveAll() async {
        let records = (0..<60).map { index in
            SyncApprovalFixture.newConnection(
                String(format: "00000000-0000-4000-8000-%012d", index),
                name: "Library \(index)"
            )
        }
        let engine = FakeSyncApprovalEngine(records)
        let writes = Writes()
        let model = Self.model(engine, writes: writes)
        await model.refresh()
        #expect(model.waiting == 60)

        await model.approveAll(model.records)

        #expect(engine.decided == records.map { "\($0.record.recordId) approve" })
        #expect(model.records.isEmpty)
        #expect(model.waiting == 0)
        #expect(writes.reads == 1)
        #expect(!model.isDeciding)
    }

    @Test("Approve All leaves a record a pull changed meanwhile for the person, and still approves the others")
    func approveAllSkipsChanged() async {
        let first = SyncApprovalFixture.newConnection()
        let second = SyncApprovalFixture.changedConnection()
        let engine = FakeSyncApprovalEngine([first, second])
        let model = Self.model(engine)
        await model.refresh()
        let pulledAgain = SyncApprovalFixture.newConnection(host: "db2.example.com")
        engine.set([pulledAgain, second])

        await model.approveAll([first, second])

        #expect(engine.decided == ["\(SyncApprovalFixture.changedID) approve"])
        #expect(model.records == [pulledAgain])
        #expect(model.failure?.record == nil)
        #expect(model.failure?.message == SyncApprovalsModel.changedAgainAllMessage)
    }

    @Test("Approve All stops at a refusal, so nothing after it is approved unseen")
    func approveAllStopsOnFailure() async {
        let first = SyncApprovalFixture.newConnection()
        let second = SyncApprovalFixture.changedConnection()
        let engine = FakeSyncApprovalEngine([first, second])
        engine.failDecision(on: SyncApprovalFixture.newID, with: SyncApprovalFixture.failure("sync.state.busy"))
        let model = Self.model(engine)
        await model.refresh()

        await model.approveAll(model.records)

        #expect(engine.decided.isEmpty)
        #expect(model.records == [first, second])
        #expect(model.failure == SyncApprovalFailure(record: nil, message: SyncApprovalsModel.saveFailedMessage))
    }

    @Test("A read that began before a decision changes nothing after it")
    func staleReadDropped() async {
        let new = SyncApprovalFixture.newConnection()
        let engine = FakeSyncApprovalEngine([new])
        let model = Self.model(engine)
        await model.refresh()
        let gate = AsyncGate()
        engine.holdNextRead(at: gate)

        let stale = Task { await model.refresh() }
        await gate.arrived(1)
        await model.decide(new, approve: true)
        await gate.open()
        await stale.value

        #expect(model.records.isEmpty)
        #expect(model.waiting == 0)
    }
}

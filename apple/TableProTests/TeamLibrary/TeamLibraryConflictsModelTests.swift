//
//  TeamLibraryConflictsModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport
import Testing

@MainActor
struct TeamLibraryConflictsModelTests {
    private static func model(_ engine: FakeTeamConflictEngine) -> TeamLibraryConflictsModel {
        TeamLibraryConflictsModel(engine: { engine })
    }

    private static func choices(_ engine: FakeTeamConflictEngine) -> [String] {
        engine.choices.map { "\($0.record.recordId) \($0.keep)" }
    }

    @Test("A refresh shows the engine's conflicts, named by the team names Team Library gives")
    func refreshShowsConflicts() async {
        let conflict = TeamConflictFixture.conflict()
        let engine = FakeTeamConflictEngine([conflict])
        let model = Self.model(engine)

        await model.refresh()
        let writerKey = TeamLibraryConflictsModel.writerKey(scope: TeamConflictFixture.team, kind: "library_query", id: "Q1")
        model.name([TeamConflictFixture.team: "Acme"], writers: [writerKey: "Grace Hopper"])

        #expect(model.conflicts == [conflict])
        #expect(model.teamName(of: TeamConflictFixture.team) == "Acme")
        #expect(model.writer(of: conflict.record) == "Grace Hopper")
    }

    @Test("The end of a sign-in clears the conflicts, and a choice still out then changes nothing on screen")
    func endClearsAndFencesChoices() async {
        let conflict = TeamConflictFixture.conflict()
        let engine = FakeTeamConflictEngine([conflict])
        let model = Self.model(engine)
        await model.refresh()
        let reads = engine.reads
        let gate = AsyncGate()
        engine.holdNextResolve(at: gate)

        let choosing = Task { await model.resolve(conflict, keep: .keepMine) }
        await gate.arrived(1)
        model.end()
        await gate.open()
        await choosing.value

        #expect(model.conflicts.isEmpty)
        #expect(model.failure(for: conflict.record) == nil)
        #expect(engine.reads == reads, "Nothing is read for a sign-in that ended")
        #expect(model.teamName(of: TeamConflictFixture.team) == nil)
    }

    @Test("A sign-in that ends while the engine opens sends the choice nowhere")
    func endWhileTheEngineOpensSendsNothing() async {
        let conflict = TeamConflictFixture.conflict()
        let engine = FakeTeamConflictEngine([conflict])
        let opening = AsyncGate()
        var holds = false
        let model = TeamLibraryConflictsModel(engine: {
            if holds { await opening.wait() }
            return engine
        })
        await model.refresh()
        holds = true

        let choosing = Task { await model.resolve(conflict, keep: .keepTheirs) }
        await opening.arrived(1)
        model.end()
        await opening.open()
        await choosing.value

        #expect(Self.choices(engine).isEmpty)
    }

    @Test("A failed read keeps the conflicts already shown")
    func failedReadKeepsConflicts() async {
        let conflict = TeamConflictFixture.conflict()
        let engine = FakeTeamConflictEngine([conflict])
        let model = Self.model(engine)
        await model.refresh()

        engine.set([])
        engine.failReads(with: TeamConflictFixture.failure("sync.state.io"))
        await model.refresh()

        #expect(model.conflicts == [conflict])
    }

    @Test("Keep Mine and Keep Theirs reach the engine with the record, and the conflict leaves the list")
    func choicesReachTheEngine() async {
        let orders = TeamConflictFixture.conflict("q1")
        let customers = TeamConflictFixture.conflict("q2")
        let engine = FakeTeamConflictEngine([orders, customers])
        let model = Self.model(engine)
        await model.refresh()

        await model.resolve(orders, keep: .keepMine)
        #expect(model.conflicts == [customers])
        await model.resolve(customers, keep: .keepTheirs)

        #expect(Self.choices(engine) == ["q1 keepMine", "q2 keepTheirs"])
        #expect(model.conflicts.isEmpty)
        #expect(model.resolving == nil)
    }

    @Test("A choice the engine refuses keeps the conflict and says so until a choice is saved")
    func refusedChoiceKeepsTheConflict() async {
        let conflict = TeamConflictFixture.conflict()
        let engine = FakeTeamConflictEngine([conflict])
        let model = Self.model(engine)
        await model.refresh()

        engine.failResolves(with: TeamConflictFixture.failure("sync.adapter.store"))
        await model.resolve(conflict, keep: .keepMine)

        #expect(model.conflicts == [conflict])
        #expect(model.failure(for: conflict.record) == String(localized: "TablePro couldn't save your choice. Try again."))
        #expect(model.failure(for: TeamConflictFixture.record("other")) == nil)

        engine.failResolves(with: nil)
        await model.resolve(conflict, keep: .keepTheirs)
        #expect(model.failure(for: conflict.record) == nil)
        #expect(model.conflicts.isEmpty)
    }

    @Test("A conflict another pass settled before the choice closes without an error or a choice")
    func settledConflictClosesQuietly() async {
        let conflict = TeamConflictFixture.conflict()
        let engine = FakeTeamConflictEngine([conflict])
        let model = Self.model(engine)
        await model.refresh()

        engine.set([])
        await model.resolve(conflict, keep: .keepMine)

        #expect(Self.choices(engine).isEmpty)
        #expect(model.failure(for: conflict.record) == nil)
        #expect(model.conflicts.isEmpty)
    }

    @Test("An engine that no longer knows the conflict when the choice lands reports no error")
    func unknownConflictAtTheChoiceIsNoError() async {
        let conflict = TeamConflictFixture.conflict()
        let engine = FakeTeamConflictEngine([conflict])
        let model = Self.model(engine)
        await model.refresh()

        engine.failResolves(with: TeamConflictFixture.failure("sync.unknown"))
        await model.resolve(conflict, keep: .keepMine)

        #expect(model.failure(for: conflict.record) == nil)
        #expect(model.resolving == nil)
    }

    @Test("A conflict a pull replaced since the sheet showed it is shown again, not resolved")
    func replacedConflictIsShownAgain() async {
        let shown = TeamConflictFixture.conflict(theirs: ["name": "Orders", "query": "select theirs"])
        let replaced = TeamConflictFixture.conflict(theirs: ["name": "Orders", "query": "select newer"])
        let engine = FakeTeamConflictEngine([shown])
        let model = Self.model(engine)
        await model.refresh()

        engine.set([replaced])
        await model.resolve(shown, keep: .keepTheirs)

        #expect(Self.choices(engine).isEmpty)
        #expect(model.conflicts == [replaced])
        #expect(model.failure(for: replaced.record) == String(localized: "This item changed again. Review the new version, then choose."))

        await model.resolve(replaced, keep: .keepTheirs)
        #expect(Self.choices(engine) == ["q1 keepTheirs"])
        #expect(model.failure(for: replaced.record) == nil)
    }

    @Test("A read that started before a choice does not bring the resolved conflict back")
    func staleReadAfterAChoiceChangesNothing() async {
        let conflict = TeamConflictFixture.conflict()
        let engine = FakeTeamConflictEngine([conflict])
        let model = Self.model(engine)
        await model.refresh()

        let gate = AsyncGate()
        engine.holdNextRead(at: gate)
        let stale = Task { await model.refresh() }
        await gate.arrived(1)
        await model.resolve(conflict, keep: .keepTheirs)
        await gate.open()
        await stale.value

        #expect(model.conflicts.isEmpty)
    }
}

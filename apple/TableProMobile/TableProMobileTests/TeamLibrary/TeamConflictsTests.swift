import Foundation
import TableProFFI
@testable import TableProMobile
import Testing

private let record = SyncRecordRef(scope: "team_a", kind: "library_query", recordId: "q1")

private func conflict(mine: String?, theirs: String?, fields: [String] = ["query", "name"]) -> TeamConflictInfo {
    TeamConflictInfo(record: record, fields: fields, mine: mine, theirs: theirs, digest: "d1")
}

@MainActor
struct TeamConflictsTests {
    @Test("Both sides changed: the fields come in the editor's order with each side's value")
    func bothChanged() {
        let presentation = TeamConflictPresentation(
            conflict: conflict(mine: #"{"name":"Daily","query":"SELECT 1"}"#, theirs: #"{"name":"Daily v2","query":"SELECT 2"}"#),
            teamName: "Analytics",
            writer: " Ana "
        )

        #expect(presentation.shape == .bothChanged)
        #expect(presentation.rows.map(\.field) == ["name", "query"])
        #expect(presentation.rows.last?.mine == .code("SELECT 1"))
        #expect(presentation.rows.last?.theirs == .code("SELECT 2"))
        #expect(presentation.writer == "Ana")
        #expect(presentation.title.contains("Daily"))
    }

    @Test("A side that deleted the item has no column, and the hints say what each choice does")
    func deletionShapes() {
        let youDeleted = TeamConflictPresentation(conflict: conflict(mine: nil, theirs: #"{"name":"Daily"}"#), teamName: nil)
        let teamDeleted = TeamConflictPresentation(conflict: conflict(mine: #"{"name":"Daily"}"#, theirs: nil), teamName: nil)

        #expect(youDeleted.shape == .youDeleted)
        #expect(youDeleted.rows.allSatisfy { $0.mine == nil })
        #expect(teamDeleted.shape == .teamDeleted)
        #expect(teamDeleted.keepTheirsHint == String(localized: "Leaves the item deleted"))
    }

    @Test("A choice the engine refuses as changed shows the new version with a note to look again")
    func changedAgain() async {
        let engine = FakeTeamLibraryCalls()
        let shown = conflict(mine: #"{"name":"A"}"#, theirs: #"{"name":"B"}"#)
        engine.update { $0.conflicts = [shown] }
        engine.fail("resolve", with: FakeTeamLibraryCalls.failure("sync.changed"))
        let model = TeamConflictsModel(engine: { engine })
        await model.refresh()

        await model.resolve(shown, keep: .keepMine)

        #expect(model.failure(for: record) == String(localized: "This item changed again. Review the new version, then choose."))
        #expect(model.conflicts == [shown])
    }

    @Test("A choice that went through takes the conflict off the list")
    func resolved() async {
        let engine = FakeTeamLibraryCalls()
        let shown = conflict(mine: #"{"name":"A"}"#, theirs: #"{"name":"B"}"#)
        engine.update { $0.conflicts = [shown] }
        let model = TeamConflictsModel(engine: { engine })
        await model.refresh()

        await model.resolve(shown, keep: .keepTheirs)

        #expect(model.conflicts.isEmpty)
        #expect(engine.read { $0.resolved.first?.keep } == .keepTheirs)
    }

    @Test("Ending the sign-in forgets every conflict, name and writer")
    func endForgets() async {
        let engine = FakeTeamLibraryCalls()
        engine.update { $0.conflicts = [conflict(mine: "{}", theirs: "{}")] }
        let model = TeamConflictsModel(engine: { engine })
        await model.refresh()
        model.name(["team_a": "Analytics"], writers: ["k": "Ana"])

        model.end()

        #expect(model.conflicts.isEmpty)
        #expect(model.teamName(of: "team_a") == nil)
        #expect(model.writers.isEmpty)
    }
}

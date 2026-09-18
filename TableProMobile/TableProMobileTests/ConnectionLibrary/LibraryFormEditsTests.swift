import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Group and tag form edits")
struct LibraryFormEditsTests {
    @Test("A group rename keeps a color and a parent changed after the sheet opened, and trims the name")
    func groupRenameKeepsOtherChanges() {
        let parentId = UUID()
        let opened = ConnectionGroup(name: "Clients", sortOrder: 2, color: .red)
        var current = opened
        current.color = .blue
        current.parentId = parentId

        let edits = GroupFormEdits(name: "  Customers ", color: .red, parentId: nil)
        let saved = edits.applied(to: current, changedSince: GroupFormEdits(group: opened))

        #expect(saved.name == "Customers")
        #expect(saved.color == .blue)
        #expect(saved.parentId == parentId)
        #expect(saved.sortOrder == 2)
    }

    @Test("A tag rename keeps a color changed after the sheet opened")
    func tagRenameKeepsColor() {
        let opened = ConnectionTag(name: "staging", color: .orange)
        var current = opened
        current.color = .pink

        let edits = TagFormEdits(name: "stage", color: .orange)
        let saved = edits.applied(to: current, changedSince: TagFormEdits(tag: opened))

        #expect(saved.name == "stage")
        #expect(saved.color == .pink)
    }

    @Test("With nothing to compare against, every field is written")
    func nilOpeningWritesEverything() {
        let parentId = UUID()
        let group = GroupFormEdits(name: "Team", color: .green, parentId: parentId)
            .applied(to: ConnectionGroup(), changedSince: nil)
        let tag = TagFormEdits(name: "local", color: .yellow)
            .applied(to: ConnectionTag(), changedSince: nil)

        #expect(group.name == "Team")
        #expect(group.color == .green)
        #expect(group.parentId == parentId)
        #expect(tag.name == "local")
        #expect(tag.color == .yellow)
    }

    @Test("Only a saved write closes a form without an alert, and only a removed item closes it after one")
    func writeOutcomesMapToFailures() throws {
        #expect(LibraryWriteFailure(.applied, kind: .group) == nil)
        #expect(LibraryWriteFailure(.unchanged, kind: .tag) == nil)
        #expect(LibraryWriteFailure(.missing, kind: .tag) == .removed(.tag))
        #expect(LibraryWriteFailure(.refused, kind: .connection) == .libraryUnavailable(.connection))
        #expect(LibraryWriteFailure(.invalidPlacement, kind: .group) == .invalidPlacement)

        let removed = try #require(LibraryWriteFailure(.missing, kind: .group))
        let refused = try #require(LibraryWriteFailure(.refused, kind: .group))
        let misplaced = try #require(LibraryWriteFailure(.invalidPlacement, kind: .group))
        #expect(removed.closesForm)
        #expect(!refused.closesForm)
        #expect(!misplaced.closesForm)
    }
}

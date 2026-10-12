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

        let edits = GroupFormEdits(name: "  Customers ", color: .red, iconName: nil, parentId: nil)
        let saved = edits.applied(to: current, changedSince: GroupFormEdits(group: opened))

        #expect(saved.name == "Customers")
        #expect(saved.color == .blue)
        #expect(saved.parentId == parentId)
        #expect(saved.sortOrder == 2)
    }

    @Test("A group rename keeps an icon another device set after the sheet opened")
    func groupRenameKeepsSyncedIcon() {
        let opened = ConnectionGroup(name: "Clients", iconName: "briefcase")
        var current = opened
        current.iconName = "flame"

        let edits = GroupFormEdits(name: "Customers", color: .none, iconName: "briefcase", parentId: nil)
        let saved = edits.applied(to: current, changedSince: GroupFormEdits(group: opened))

        #expect(saved.name == "Customers")
        #expect(saved.iconName == "flame")
    }

    @Test("Picking an icon writes it, and picking Default clears it")
    func groupIconPickAndReset() {
        let plain = ConnectionGroup(name: "Clients")
        let picked = GroupFormEdits(name: "Clients", color: .none, iconName: "briefcase", parentId: nil)
            .applied(to: plain, changedSince: GroupFormEdits(group: plain))
        #expect(picked.iconName == "briefcase")

        let reset = GroupFormEdits(name: "Clients", color: .none, iconName: nil, parentId: nil)
            .applied(to: picked, changedSince: GroupFormEdits(group: picked))
        #expect(reset.iconName == nil)
    }

    @Test("A group icon this release does not know is kept, and one that is not a symbol name is not")
    func groupIconIsNormalized() {
        let unknown = ConnectionGroup(name: "Clients", iconName: "made.up.symbol")
        #expect(GroupFormEdits(group: unknown).iconName == "made.up.symbol")
        #expect(
            GroupFormEdits(name: "Clients", color: .none, iconName: "made.up.symbol", parentId: nil)
                .applied(to: unknown, changedSince: GroupFormEdits(group: unknown)) == unknown
        )
        #expect(GroupFormEdits(name: "Clients", color: .none, iconName: " ", parentId: nil).iconName == nil)
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
        let group = GroupFormEdits(name: "Team", color: .green, iconName: "briefcase", parentId: parentId)
            .applied(to: ConnectionGroup(), changedSince: nil)
        let tag = TagFormEdits(name: "local", color: .yellow)
            .applied(to: ConnectionTag(), changedSince: nil)

        #expect(group.name == "Team")
        #expect(group.color == .green)
        #expect(group.iconName == "briefcase")
        #expect(group.parentId == parentId)
        #expect(tag.name == "local")
        #expect(tag.color == .yellow)
    }

    @Test("A new group opens empty under the group it was created from, and an edited one mirrors its record")
    func groupOpeningState() {
        let parent = UUID()
        let blank = GroupFormEdits(opening: nil, parentId: parent)
        #expect(blank.name.isEmpty)
        #expect(blank.color == .none)
        #expect(blank.iconName == nil)
        #expect(blank.parentId == parent)

        let group = ConnectionGroup(name: "Team", color: .blue, iconName: "person.3", parentId: parent)
        #expect(GroupFormEdits(opening: group, parentId: nil).iconName == "person.3")
        #expect(GroupFormEdits(opening: group, parentId: nil) == GroupFormEdits(group: group))
    }

    @Test("A new tag opens empty and gray, and an edited one mirrors its record")
    func tagOpeningState() {
        let blank = TagFormEdits(opening: nil)
        #expect(blank.name.isEmpty)
        #expect(blank.color == .gray)

        let tag = ConnectionTag(name: "Staging", color: .orange)
        #expect(TagFormEdits(opening: tag) == TagFormEdits(tag: tag))
    }

    @Test("A rename, recolor or move differs from where the form opened, and spaces around a group name do not")
    func editsDifferFromOpening() {
        let tag = TagFormEdits(opening: ConnectionTag(name: "Staging", color: .orange))
        #expect(TagFormEdits(name: "QA", color: .orange) != tag)
        #expect(TagFormEdits(name: "Staging", color: .red) != tag)
        #expect(TagFormEdits(name: "Staging", color: .orange) == tag)

        let group = GroupFormEdits(opening: ConnectionGroup(name: "Team"), parentId: nil)
        #expect(GroupFormEdits(name: "Team", color: group.color, iconName: nil, parentId: UUID()) != group)
        #expect(GroupFormEdits(name: "Team", color: group.color, iconName: "flame", parentId: nil) != group)
        #expect(GroupFormEdits(name: " Team ", color: group.color, iconName: nil, parentId: nil) == group)
        #expect(
            GroupFormEdits(name: "  ", color: .none, iconName: nil, parentId: nil)
                == GroupFormEdits(opening: nil, parentId: nil)
        )
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

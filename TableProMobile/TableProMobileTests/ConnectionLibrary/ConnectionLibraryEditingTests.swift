import Foundation
import TableProConnectionLibrary
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Connection library editing")
struct ConnectionLibraryEditingTests {
    @Test("A new connection goes to the end of its group, and a missing group counts as ungrouped")
    func addingPlacesAtEnd() {
        let groupId = UUID()
        let grouped = DatabaseConnection(name: "A", type: .mysql, groupId: groupId, sortOrder: 4)
        let loose = DatabaseConnection(name: "B", type: .mysql, sortOrder: 7)
        let orphan = DatabaseConnection(name: "Orphan", type: .mysql, groupId: UUID(), sortOrder: 9)
        let existing = [grouped, loose, orphan]

        let intoGroup = ConnectionLibraryEditing.adding(
            DatabaseConnection(name: "New", type: .mysql, groupId: groupId),
            to: existing,
            validGroupIds: [groupId]
        )
        let ungrouped = ConnectionLibraryEditing.adding(
            DatabaseConnection(name: "Loose", type: .mysql),
            to: existing,
            validGroupIds: [groupId]
        )

        #expect(intoGroup.connections.last?.sortOrder == 5)
        #expect(ungrouped.connections.last?.sortOrder == 10)
    }

    @Test("Editing a connection into another group puts it at the end there, and an edit in place keeps its spot")
    func updatingMovesOnlyOnGroupChange() throws {
        let groupId = UUID()
        let member = DatabaseConnection(name: "Member", type: .mysql, groupId: groupId, sortOrder: 3)
        let editing = DatabaseConnection(name: "Editing", type: .mysql, sortOrder: 1)

        let inPlace = try #require(ConnectionLibraryEditing.mutatingConnection(
            editing.id, in: [member, editing], validGroupIds: [groupId]
        ) { $0.name = "Renamed" })

        let moved = try #require(ConnectionLibraryEditing.mutatingConnection(
            editing.id, in: [member, editing], validGroupIds: [groupId]
        ) { $0.groupId = groupId })

        #expect(inPlace.connections.first { $0.id == editing.id }?.sortOrder == 1)
        #expect(inPlace.changedConnectionIds == [editing.id])
        #expect(moved.connections.first { $0.id == editing.id }?.sortOrder == 4)
    }

    @Test("Editing a connection that is no longer stored changes nothing")
    func mutatingMissingConnection() {
        let stored = DatabaseConnection(name: "Stored", type: .mysql)

        let change = ConnectionLibraryEditing.mutatingConnection(UUID(), in: [stored], validGroupIds: []) {
            $0.name = "Resurrected"
        }

        #expect(change == nil)
    }

    @Test("An edit that leaves the record as it was reports no changed connection")
    func mutatingWithoutChange() throws {
        let stored = DatabaseConnection(name: "Stored", type: .mysql, sortOrder: 3)

        let change = try #require(ConnectionLibraryEditing.mutatingConnection(
            stored.id, in: [stored], validGroupIds: []
        ) { $0.name = "Stored" })

        #expect(change.changedConnectionIds.isEmpty)
        #expect(change.connections == [stored])
    }

    @Test("A group edit keeps its place unless its parent changes")
    func groupEditKeepsSortOrder() throws {
        let parent = ConnectionGroup(name: "Parent", sortOrder: 0)
        let sibling = ConnectionGroup(name: "Sibling", sortOrder: 0, parentId: parent.id)
        let editing = ConnectionGroup(name: "Editing", sortOrder: 5)
        let groups = [parent, sibling, editing]

        let renamed = try #require(ConnectionLibraryEditing.mutatingGroup(editing.id, in: groups) {
            $0.name = "Renamed"
        })
        let moved = try #require(ConnectionLibraryEditing.mutatingGroup(editing.id, in: groups) {
            $0.parentId = parent.id
        })

        #expect(renamed.changed)
        #expect(renamed.groups.first { $0.id == editing.id }?.sortOrder == 5)
        #expect(moved.groups.first { $0.id == editing.id }?.sortOrder == 1)
        #expect(ConnectionLibraryEditing.mutatingGroup(UUID(), in: groups) { $0.name = "Gone" } == nil)
    }

    @Test("A tag edit touches that one tag")
    func mutatingTagTouchesOneTag() throws {
        let edited = ConnectionTag(name: "staging", color: .blue)
        let other = ConnectionTag(name: "prod", color: .red)

        let result = try #require(ConnectionLibraryEditing.mutatingTag(edited.id, in: [edited, other]) {
            $0.name = "stage"
        })
        let untouched = try #require(ConnectionLibraryEditing.mutatingTag(edited.id, in: [edited, other]) {
            $0.color = .blue
        })

        #expect(result.changed)
        #expect(result.tags.map(\.name) == ["stage", "prod"])
        #expect(result.tags.last == other)
        #expect(!untouched.changed)
        #expect(ConnectionLibraryEditing.mutatingTag(UUID(), in: [edited]) { $0.name = "Gone" } == nil)
    }

    @Test("Moving before a sibling renumbers that group in the new order")
    func movingBeforeRenumbers() {
        let a = DatabaseConnection(name: "A", type: .mysql, sortOrder: 0)
        let b = DatabaseConnection(name: "B", type: .mysql, sortOrder: 1)
        let c = DatabaseConnection(name: "C", type: .mysql, sortOrder: 2)

        let change = ConnectionLibraryEditing.moving([c.id], toGroup: nil, before: a.id, in: [a, b, c], validGroupIds: [])

        let order = LibrarySorting.sorted(change.connections, mode: .manual).map(\.id)
        #expect(order == [c.id, a.id, b.id])
    }

    @Test("A duplicate sits right after its source, keeps its settings and is not a favorite")
    func duplicateFollowsSource() {
        let tagId = UUID()
        let a = DatabaseConnection(
            name: "A", type: .postgresql, color: .red, queryTimeoutSeconds: 30,
            tagIds: [tagId], sortOrder: 0, isFavorite: true
        )
        let b = DatabaseConnection(name: "B", type: .mysql, sortOrder: 1)

        let result = ConnectionLibraryEditing.duplicating(a, named: "A Copy", in: [a, b], validGroupIds: [])

        let order = LibrarySorting.sorted(result.change.connections, mode: .manual).map(\.id)
        #expect(order == [a.id, result.copy.id, b.id])
        #expect(result.copy.name == "A Copy")
        #expect(result.copy.color == .red)
        #expect(result.copy.queryTimeoutSeconds == 30)
        #expect(result.copy.tagIds == [tagId])
        #expect(!result.copy.isFavorite)
        #expect(result.change.changedConnectionIds.contains(b.id))
    }

    @Test("Deleting a group deletes its subgroups and moves all their connections to Ungrouped")
    func deletingGroupCascades() {
        let top = ConnectionGroup(name: "Clients", sortOrder: 0)
        let middle = ConnectionGroup(name: "Acme", sortOrder: 0, parentId: top.id)
        let bottom = ConnectionGroup(name: "Europe", sortOrder: 0, parentId: middle.id)
        let unrelated = ConnectionGroup(name: "Internal", sortOrder: 1)
        let loose = DatabaseConnection(name: "Loose", type: .mysql, sortOrder: 2)
        let deep = DatabaseConnection(name: "Deep", type: .mysql, groupId: bottom.id, sortOrder: 0)
        let kept = DatabaseConnection(name: "Kept", type: .mysql, groupId: unrelated.id, sortOrder: 0)

        let change = ConnectionLibraryEditing.deletingGroup(
            top.id,
            groups: [top, middle, bottom, unrelated],
            connections: [loose, deep, kept]
        )

        #expect(Set(change.removedGroupIds) == [top.id, middle.id, bottom.id])
        #expect(change.groups.map(\.id) == [unrelated.id])
        let movedDeep = change.connections.first { $0.id == deep.id }
        #expect(movedDeep?.groupId == nil)
        #expect(movedDeep?.sortOrder == 3)
        #expect(change.connections.first { $0.id == kept.id }?.groupId == unrelated.id)
        #expect(change.changedConnectionIds == [deep.id])
    }

    @Test("Favoriting reports only the connections whose flag changed")
    func favoritingReportsChanges() {
        let already = DatabaseConnection(name: "Already", type: .mysql, isFavorite: true)
        let plain = DatabaseConnection(name: "Plain", type: .mysql)

        let change = ConnectionLibraryEditing.settingFavorite([already.id, plain.id], to: true, in: [already, plain])

        #expect(change.changedConnectionIds == [plain.id])
        #expect(change.connections.allSatisfy { $0.isFavorite })
    }

    @Test("A rename is trimmed and a blank one changes nothing")
    func renaming() {
        let prod = DatabaseConnection(name: "Prod", type: .mysql)

        let renamed = ConnectionLibraryEditing.renaming(prod.id, to: "  Production ", in: [prod])
        let blank = ConnectionLibraryEditing.renaming(prod.id, to: "   ", in: [prod])

        #expect(renamed.connections.first?.name == "Production")
        #expect(blank.changedConnectionIds.isEmpty)
    }

    @Test("Tag counts include every tag on a connection, not only the first")
    func tagCountsReadEveryTag() {
        let first = UUID()
        let second = UUID()
        let both = DatabaseConnection(name: "Both", type: .mysql, tagIds: [first, second])
        let onlySecond = DatabaseConnection(name: "Second", type: .mysql, tagIds: [second])

        let counts = ConnectionLibraryEditing.tagUsageCounts(in: [both, onlySecond])

        #expect(counts[first] == 1)
        #expect(counts[second] == 2)
    }

    @Test("A group cannot go past three levels or under its own subgroup")
    func groupPlacementIsChecked() throws {
        let one = ConnectionGroup(name: "1")
        let two = ConnectionGroup(name: "2", parentId: one.id)
        let three = ConnectionGroup(name: "3", parentId: two.id)
        let groups = [one, two, three]

        #expect(ConnectionLibraryEditing.addingGroup(ConnectionGroup(name: "4", parentId: three.id), to: groups) == nil)
        let added = try #require(ConnectionLibraryEditing.addingGroup(ConnectionGroup(name: "Sibling", parentId: one.id), to: groups))
        #expect(added.last?.sortOrder == 1)

        #expect(ConnectionLibraryEditing.mutatingGroup(one.id, in: groups) { $0.parentId = two.id } == nil)
    }
}

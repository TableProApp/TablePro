import Foundation
import TableProConnectionLibrary
@testable import TableProMobile
import TableProModels
import Testing

struct ConnectionProjectEditingTests {
    private let projectId = UUID()
    private let otherProjectId = UUID()

    @Test("A connection moved out of its group keeps the project of the top-level group it left")
    func movingOutKeepsTheProject() {
        let root = ConnectionGroup(name: "Acme", projectId: projectId)
        let child = ConnectionGroup(name: "Production", parentId: root.id)
        let member = DatabaseConnection(name: "Orders", type: .mysql, groupId: child.id)

        let change = ConnectionLibraryEditing.moving([member.id], toGroup: nil, in: [member], groups: [root, child])

        #expect(change.connections.first?.groupId == nil)
        #expect(change.connections.first?.projectId == projectId)
    }

    @Test("A connection moved into a group stops storing a project of its own")
    func movingInClearsTheStoredProject() {
        let group = ConnectionGroup(name: "Acme", projectId: otherProjectId)
        let loose = DatabaseConnection(name: "Orders", type: .mysql, projectId: projectId)

        let change = ConnectionLibraryEditing.moving([loose.id], toGroup: group.id, in: [loose], groups: [group])

        #expect(change.connections.first?.groupId == group.id)
        #expect(change.connections.first?.projectId == nil)
    }

    @Test("Deleting a group leaves its connections in the group's project, not in one they stored before")
    func deletingAGroupStampsItsProject() {
        let root = ConnectionGroup(name: "Acme", projectId: projectId)
        let child = ConnectionGroup(name: "Production", parentId: root.id)
        let stale = DatabaseConnection(name: "Orders", type: .mysql, groupId: child.id, projectId: otherProjectId)

        let change = ConnectionLibraryEditing.deletingGroup(root.id, groups: [root, child], connections: [stale])

        #expect(change.groups.isEmpty)
        #expect(change.connections.first?.groupId == nil)
        #expect(change.connections.first?.projectId == projectId)
    }

    @Test("A form save that changes the group follows the same rules, and one that names a project keeps it")
    func formSaveNormalizes() throws {
        let group = ConnectionGroup(name: "Acme", projectId: projectId)
        let grouped = DatabaseConnection(name: "Orders", type: .mysql, groupId: group.id)
        let loose = DatabaseConnection(name: "Loose", type: .mysql, projectId: otherProjectId)

        let ungrouped = try #require(ConnectionLibraryEditing.mutatingConnection(
            grouped.id, in: [grouped, loose], groups: [group]
        ) { $0.groupId = nil })
        let joined = try #require(ConnectionLibraryEditing.mutatingConnection(
            loose.id, in: [grouped, loose], groups: [group]
        ) { $0.groupId = group.id })
        let assigned = try #require(ConnectionLibraryEditing.mutatingConnection(
            loose.id, in: [grouped, loose], groups: [group]
        ) { $0.projectId = projectId })

        #expect(ungrouped.connections.first { $0.id == grouped.id }?.projectId == projectId)
        #expect(joined.connections.first { $0.id == loose.id }?.projectId == nil)
        #expect(assigned.connections.first { $0.id == loose.id }?.projectId == projectId)
    }

    @Test("A new connection in a group stores no project, and a new subgroup stores none either")
    func addingNormalizes() throws {
        let group = ConnectionGroup(name: "Acme", projectId: projectId)

        let added = ConnectionLibraryEditing.adding(
            DatabaseConnection(name: "New", type: .mysql, groupId: group.id, projectId: otherProjectId),
            to: [],
            groups: [group]
        )
        let groups = try #require(ConnectionLibraryEditing.addingGroup(
            ConnectionGroup(name: "Sub", parentId: group.id, projectId: otherProjectId),
            to: [group]
        ))

        #expect(added.connections.first?.projectId == nil)
        #expect(groups.last?.projectId == nil)
    }

    @Test("A subgroup moved to the top level takes its old root's project, and a root moved under another drops its own")
    func movingGroupsNormalizes() throws {
        let root = ConnectionGroup(name: "Acme", projectId: projectId)
        let child = ConnectionGroup(name: "Production", parentId: root.id)
        let other = ConnectionGroup(name: "Internal", projectId: otherProjectId)
        let groups = [root, child, other]

        let lifted = try #require(ConnectionLibraryEditing.mutatingGroup(child.id, in: groups) { $0.parentId = nil })
        let nested = try #require(ConnectionLibraryEditing.mutatingGroup(other.id, in: groups) { $0.parentId = root.id })

        #expect(lifted.groups.first { $0.id == child.id }?.projectId == projectId)
        #expect(nested.groups.first { $0.id == other.id }?.projectId == nil)
    }

    @Test("Move to Project changes an ungrouped connection and a top-level group, and leaves what follows a group")
    func assigningSkipsWhatFollowsAGroup() {
        let root = ConnectionGroup(name: "Acme")
        let child = ConnectionGroup(name: "Production", parentId: root.id)
        let loose = DatabaseConnection(name: "Loose", type: .mysql)
        let grouped = DatabaseConnection(name: "Grouped", type: .mysql, groupId: child.id)

        let change = ConnectionLibraryEditing.assigningProject(
            projectId,
            toConnections: [loose.id, grouped.id],
            groups: [root.id, child.id],
            in: [loose, grouped],
            groups: [root, child]
        )

        #expect(change.changedConnectionIds == [loose.id])
        #expect(change.changedGroupIds == [root.id])
        #expect(change.groups.first { $0.id == child.id }?.projectId == nil)
    }

    @Test("Deleting a project keeps its groups and connections and clears only their membership")
    func deletingAProjectKeepsItsMembers() throws {
        let project = ConnectionProject(id: projectId, name: "Acme")
        let kept = ConnectionProject(id: otherProjectId, name: "Internal")
        let group = ConnectionGroup(name: "Production", projectId: projectId)
        let member = DatabaseConnection(name: "Loose", type: .mysql, projectId: projectId)
        let outsider = DatabaseConnection(name: "Other", type: .mysql, projectId: otherProjectId)

        let change = try #require(ConnectionLibraryEditing.deletingProject(
            projectId,
            projects: [project, kept],
            groups: [group],
            connections: [member, outsider]
        ))

        #expect(change.projects == [kept])
        #expect(change.groups.map(\.projectId) == [nil])
        #expect(change.connections.map(\.projectId) == [nil, otherProjectId])
        #expect(change.changedConnectionIds == [member.id])
        #expect(change.changedGroupIds == [group.id])
    }

    @Test("A project name is trimmed, and an empty one or one that differs only in case or Unicode form is refused")
    func projectNames() {
        let existing = ConnectionProject(name: "Café", sortOrder: 4)

        let added = ConnectionLibraryEditing.addingProject(named: "  Acme ", to: [existing])
        let empty = ConnectionLibraryEditing.addingProject(named: "   ", to: [existing])
        let decomposed = ConnectionLibraryEditing.addingProject(named: "CAFE\u{301}", to: [existing])
        let sameName = ConnectionLibraryEditing.renamingProject(existing.id, to: "café", in: [existing])

        #expect(added.projects.last?.name == "Acme")
        #expect(added.projects.last?.sortOrder == 5)
        #expect(empty.outcome == .emptyName)
        #expect(decomposed.outcome == .duplicateName)
        #expect(sameName.outcome == .applied(existing.id))
    }
}

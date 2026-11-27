import Foundation
@testable import TableProConnectionLibrary
import Testing

struct LibraryPullMembershipTests {
    private let acme = UUID()
    private let globex = UUID()

    @Test("A connection the pull already took out of a deleted group keeps that group's project")
    func releasedConnectionKeepsTheProject() {
        let group = FixtureGroup(name: "Production", projectId: acme)
        let member = FixtureConnection(name: "orders", groupId: group.id)
        var released = member
        released.groupId = nil

        let changes = LibraryPullMembership.keptByReleasedMembers(
            ofGroups: [group.id],
            connectionsBefore: [member],
            groupsBefore: [group],
            connections: [released],
            groups: [FixtureGroup]()
        )

        #expect(changes.connections == [member.id: .some(acme)])
        #expect(changes.groups.isEmpty)
    }

    @Test("A connection still naming the deleted group takes its project too")
    func memberStillNamingTheGroup() {
        let group = FixtureGroup(name: "Production", projectId: acme)
        let member = FixtureConnection(name: "orders", groupId: group.id)

        let changes = LibraryPullMembership.keptByReleasedMembers(
            ofGroups: [group.id],
            connectionsBefore: [member],
            groupsBefore: [group],
            connections: [member],
            groups: [FixtureGroup](),
            connectionsWithOwnProject: [member.id]
        )

        #expect(changes.connections == [member.id: .some(acme)])
    }

    @Test("A subgroup the pull moved to the top level keeps the project of the root it was under")
    func releasedSubgroupKeepsTheProject() {
        let root = FixtureGroup(name: "Production", projectId: acme)
        let child = FixtureGroup(name: "EU", parentId: root.id)
        let nested = FixtureConnection(name: "orders", groupId: child.id)
        var released = child
        released.parentId = nil

        let changes = LibraryPullMembership.keptByReleasedMembers(
            ofGroups: [root.id],
            connectionsBefore: [nested],
            groupsBefore: [root, child],
            connections: [nested],
            groups: [released]
        )

        #expect(changes.groups == [child.id: .some(acme)])
        #expect(changes.connections.isEmpty)
    }

    @Test("A member of a deleted subgroup keeps the project of the root that stays")
    func memberOfADeletedSubgroup() {
        let root = FixtureGroup(name: "Production", projectId: acme)
        let child = FixtureGroup(name: "EU", parentId: root.id)
        let member = FixtureConnection(name: "orders", groupId: child.id)
        var released = member
        released.groupId = nil

        let changes = LibraryPullMembership.keptByReleasedMembers(
            ofGroups: [child.id],
            connectionsBefore: [member],
            groupsBefore: [root, child],
            connections: [released],
            groups: [root]
        )

        #expect(changes.connections == [member.id: .some(acme)])
    }

    @Test("A member the pull moved into a group that stays follows that group")
    func memberMovedToAnotherGroup() {
        let deleted = FixtureGroup(name: "Production", projectId: acme)
        let other = FixtureGroup(name: "Staging", projectId: globex)
        let member = FixtureConnection(name: "orders", groupId: deleted.id)
        var moved = member
        moved.groupId = other.id

        let changes = LibraryPullMembership.keptByReleasedMembers(
            ofGroups: [deleted.id],
            connectionsBefore: [member],
            groupsBefore: [deleted, other],
            connections: [moved],
            groups: [other]
        )

        #expect(changes.isEmpty)
    }

    @Test("A released record whose project the pull set keeps what the pull sent")
    func ownProjectIsLeftAsSent() {
        let root = FixtureGroup(name: "Production", projectId: acme)
        let child = FixtureGroup(name: "EU", parentId: root.id)
        let member = FixtureConnection(name: "orders", groupId: root.id)
        var releasedMember = member
        releasedMember.groupId = nil
        releasedMember.projectId = globex
        var releasedChild = child
        releasedChild.parentId = nil

        let changes = LibraryPullMembership.keptByReleasedMembers(
            ofGroups: [root.id],
            connectionsBefore: [member],
            groupsBefore: [root, child],
            connections: [releasedMember],
            groups: [releasedChild],
            connectionsWithOwnProject: [member.id],
            groupsWithOwnProject: [child.id]
        )

        #expect(changes.isEmpty)
    }

    @Test("Records outside the deleted groups, and a pull that deletes none, change nothing")
    func untouchedRecords() {
        let group = FixtureGroup(name: "Production", projectId: acme)
        let member = FixtureConnection(name: "orders", groupId: group.id)
        let loose = FixtureConnection(name: "local", projectId: globex)

        let none = LibraryPullMembership.keptByReleasedMembers(
            ofGroups: [],
            connectionsBefore: [member, loose],
            groupsBefore: [group],
            connections: [member, loose],
            groups: [group]
        )
        let other = LibraryPullMembership.keptByReleasedMembers(
            ofGroups: [UUID()],
            connectionsBefore: [member, loose],
            groupsBefore: [group],
            connections: [member, loose],
            groups: [group]
        )

        #expect(none.isEmpty)
        #expect(other.isEmpty)
    }
}

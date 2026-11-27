import Foundation
@testable import TableProConnectionLibrary
import Testing

struct LibraryProjectScopeTests {
    private let acme = FixtureProject(name: "Acme")
    private let globex = FixtureProject(name: "Globex", sortOrder: 1)

    @Test("A top-level group's project covers its subtree and their connections")
    func subtreeFollowsTheRoot() {
        let root = FixtureGroup(name: "Production", projectId: acme.id)
        let child = FixtureGroup(name: "EU", parentId: root.id)
        let empty = FixtureGroup(name: "Empty", parentId: child.id)
        let other = FixtureGroup(name: "Production", projectId: globex.id)
        let inChild = FixtureConnection(name: "orders", groupId: child.id)
        let inOther = FixtureConnection(name: "billing", groupId: other.id)
        let loose = FixtureConnection(name: "local")

        let scoped = LibraryProjectScope.scoped(
            connections: [inChild, inOther, loose],
            groups: [root, child, empty, other],
            projects: [acme, globex],
            active: acme.id
        )

        #expect(scoped.projectId == acme.id)
        #expect(scoped.connections.map(\.id) == [inChild.id])
        #expect(scoped.connectionIds == [inChild.id])
        #expect(scoped.groups.map(\.id) == [root.id, child.id, empty.id])
    }

    @Test("A connection's own project counts only while it is ungrouped")
    func ownProjectOnlyWhenUngrouped() {
        let root = FixtureGroup(name: "Shared", projectId: globex.id)
        let grouped = FixtureConnection(name: "a", groupId: root.id, projectId: acme.id)
        let ungrouped = FixtureConnection(name: "b", projectId: acme.id)
        let orphan = FixtureConnection(name: "c", groupId: UUID(), projectId: acme.id)
        let scope = LibraryProjectScope(groups: [root], projects: [acme, globex])

        #expect(scope.effectiveProjectId(of: grouped) == globex.id)
        #expect(scope.effectiveProjectId(of: ungrouped) == acme.id)
        #expect(scope.effectiveProjectId(of: orphan) == acme.id)
    }

    @Test("A project stored on a child group is ignored")
    func childGroupProjectIsIgnored() {
        let root = FixtureGroup(name: "Root", projectId: acme.id)
        let child = FixtureGroup(name: "Child", parentId: root.id, projectId: globex.id)
        let connection = FixtureConnection(name: "a", groupId: child.id)
        let scope = LibraryProjectScope(groups: [root, child], projects: [acme, globex])

        #expect(scope.effectiveProjectId(of: child) == acme.id)
        #expect(scope.effectiveProjectId(of: connection) == acme.id)
    }

    @Test("A project id no project holds reads as no project and the record stays listed")
    func unknownProjectReadsAsNone() {
        let missing = UUID()
        let root = FixtureGroup(name: "Root", projectId: missing)
        let grouped = FixtureConnection(name: "a", groupId: root.id)
        let loose = FixtureConnection(name: "b", projectId: missing)
        let scope = LibraryProjectScope(groups: [root], projects: [acme])

        #expect(scope.effectiveProjectId(of: root) == nil)
        #expect(scope.effectiveProjectId(of: grouped) == nil)
        #expect(scope.effectiveProjectId(of: loose) == nil)
        #expect(scope.storedProjectId(of: grouped) == missing)

        let all = scope.scoped(connections: [grouped, loose], groups: [root], active: nil)
        #expect(all.connections.count == 2)
        let inAcme = scope.scoped(connections: [grouped, loose], groups: [root], active: acme.id)
        #expect(inAcme.connections.isEmpty)
        #expect(inAcme.groups.isEmpty)
    }

    @Test("No active project, or one that is gone, is All Connections", arguments: [nil, UUID()])
    func unknownActiveIsAllConnections(_ active: UUID?) {
        let root = FixtureGroup(name: "Root", projectId: acme.id)
        let grouped = FixtureConnection(name: "a", groupId: root.id)
        let loose = FixtureConnection(name: "b")

        let scoped = LibraryProjectScope.scoped(
            connections: [grouped, loose],
            groups: [root],
            projects: [acme],
            active: active
        )

        #expect(scoped.projectId == nil)
        #expect(scoped.connections.count == 2)
        #expect(scoped.groups.count == 1)
        #expect(scoped.connectionIds == [grouped.id, loose.id])
    }

    @Test("A group on a parent cycle is a root and keeps its own project")
    func cyclicGroupsAreRoots() {
        var first = FixtureGroup(name: "A", projectId: acme.id)
        let second = FixtureGroup(name: "B", parentId: first.id, projectId: globex.id)
        first.parentId = second.id
        let scope = LibraryProjectScope(groups: [first, second], projects: [acme, globex])

        #expect(scope.effectiveProjectId(of: first) == acme.id)
        #expect(scope.effectiveProjectId(of: second) == globex.id)
    }

    @Test("Root groups are siblings only inside one project")
    func rootSiblingsArePerProject() {
        let inAcme = FixtureGroup(name: "Production", projectId: acme.id)
        let child = FixtureGroup(name: "EU", parentId: inAcme.id)
        let unassigned = FixtureGroup(name: "Staging")
        let groups = [inAcme, child, unassigned]
        let scope = LibraryProjectScope(groups: groups, projects: [acme, globex])

        #expect(scope.siblingGroupId(named: " production ", parentId: nil, projectId: acme.id, in: groups) == inAcme.id)
        #expect(scope.siblingGroupId(named: "Production", parentId: nil, projectId: globex.id, in: groups) == nil)
        #expect(scope.siblingGroupId(named: "Production", parentId: nil, projectId: nil, in: groups) == nil)
        #expect(scope.siblingGroupId(named: "staging", parentId: nil, projectId: nil, in: groups) == unassigned.id)
        #expect(scope.siblingGroupId(named: "staging", parentId: nil, projectId: UUID(), in: groups) == unassigned.id)
        #expect(scope.siblingGroupId(named: "eu", parentId: inAcme.id, projectId: globex.id, in: groups) == child.id)
        #expect(scope.siblingGroupId(
            named: "Production", parentId: nil, projectId: acme.id, in: groups, excluding: [inAcme.id]
        ) == nil)
    }
}

struct LibraryProjectNameTests {
    @Test("An empty name is refused")
    func emptyIsRefused() {
        #expect(LibraryProjectName.problem(" \n", among: [FixtureProject]()) == .empty)
    }

    @Test("A duplicate is found across case, spaces and Unicode form")
    func duplicateAcrossForms() {
        let composed = FixtureProject(name: "Caf\u{00E9}")
        #expect(LibraryProjectName.problem("  cafe\u{0301} ", among: [composed]) == .duplicate(composed.id))
        #expect(LibraryProjectName.problem("Cafe", among: [composed]) == nil)
        #expect(LibraryProjectName.problem("CAF\u{00C9}", among: [composed], excluding: composed.id) == nil)
    }

    @Test("Of two projects with one name the first in the list order matches")
    func firstInOrderMatches() {
        let later = FixtureProject(name: "Acme", sortOrder: 4)
        let earlier = FixtureProject(name: "ACME", sortOrder: 1)
        #expect(LibraryProjectName.match("acme", in: [later, earlier])?.id == earlier.id)
        #expect(LibraryProjectName.match("", in: [later]) == nil)
    }
}

struct LibraryProjectNormalizerTests {
    private let acme = UUID()
    private let globex = UUID()

    @Test("A connection moved into a group drops its own project")
    func intoGroupClears() {
        let group = FixtureGroup(name: "G", projectId: globex)
        let moved = FixtureConnection(name: "a", projectId: acme)
        let plain = FixtureConnection(name: "b")

        let changes = LibraryProjectNormalizer.movingConnections(
            [moved.id, plain.id], toGroup: group.id, connections: [moved, plain], groups: [group]
        )

        #expect(changes.connections == [moved.id: nil])
        #expect(changes.connectionProjectId(moved.id, current: acme) == nil)
        #expect(changes.connectionProjectId(plain.id, current: nil) == nil)
    }

    @Test("A connection moved out to the root keeps the project it was in")
    func outToRootKeepsProject() {
        let root = FixtureGroup(name: "Root", projectId: acme)
        let child = FixtureGroup(name: "Child", parentId: root.id)
        let grouped = FixtureConnection(name: "a", groupId: child.id)
        let loose = FixtureConnection(name: "b", projectId: globex)

        let changes = LibraryProjectNormalizer.movingConnections(
            [grouped.id, loose.id], toGroup: nil, connections: [grouped, loose], groups: [root, child]
        )

        #expect(changes.connections == [grouped.id: acme])
        #expect(changes.connectionProjectId(loose.id, current: globex) == globex)
    }

    @Test("A project no project record holds yet still travels with the connection")
    func unknownProjectIsKept() {
        let root = FixtureGroup(name: "Root", projectId: acme)
        let grouped = FixtureConnection(name: "a", groupId: root.id)

        let changes = LibraryProjectNormalizer.movingConnections(
            [grouped.id], toGroup: nil, connections: [grouped], groups: [root]
        )

        #expect(changes.connections == [grouped.id: acme])
    }

    @Test("A group moved under another drops its own project")
    func groupUnderAnotherClears() {
        let parent = FixtureGroup(name: "Parent", projectId: globex)
        let moved = FixtureGroup(name: "Moved", projectId: acme)

        let changes = LibraryProjectNormalizer.movingGroups([moved.id], toParent: parent.id, groups: [parent, moved])

        #expect(changes.groups == [moved.id: nil])
    }

    @Test("A child group moved to the root keeps the project of the root it left")
    func childToRootKeepsProject() {
        let root = FixtureGroup(name: "Root", projectId: acme)
        let middle = FixtureGroup(name: "Middle", parentId: root.id)
        let leaf = FixtureGroup(name: "Leaf", parentId: middle.id, projectId: globex)
        let alreadyRoot = FixtureGroup(name: "Other", projectId: globex)

        let changes = LibraryProjectNormalizer.movingGroups(
            [leaf.id, alreadyRoot.id], toParent: nil, groups: [root, middle, leaf, alreadyRoot]
        )

        #expect(changes.groups == [leaf.id: acme])
    }

    @Test("Deleting a group leaves its connections in the group's project")
    func groupDeleteKeepsProject() {
        let root = FixtureGroup(name: "Root", projectId: acme)
        let child = FixtureGroup(name: "Child", parentId: root.id)
        let inRoot = FixtureConnection(name: "a", groupId: root.id, projectId: globex)
        let inChild = FixtureConnection(name: "b", groupId: child.id)
        let elsewhere = FixtureConnection(name: "c", projectId: globex)

        let changes = LibraryProjectNormalizer.deletingGroups(
            [root.id, child.id], connections: [inRoot, inChild, elsewhere], groups: [root, child]
        )

        #expect(changes.connections == [inRoot.id: acme, inChild.id: acme])
        #expect(changes.groups.isEmpty)
    }

    @Test("A child that outlives its deleted parent becomes a root of the same project")
    func survivingChildKeepsProject() {
        let root = FixtureGroup(name: "Root", projectId: acme)
        let child = FixtureGroup(name: "Child", parentId: root.id)

        let changes = LibraryProjectNormalizer.deletingGroups(
            [root.id], connections: [FixtureConnection](), groups: [root, child]
        )

        #expect(changes.groups == [child.id: acme])
    }

    @Test("Deleting a project clears it from its groups and connections and keeps them")
    func projectDeleteClears() {
        let group = FixtureGroup(name: "G", projectId: acme)
        let other = FixtureGroup(name: "H", projectId: globex)
        let loose = FixtureConnection(name: "a", projectId: acme)
        let grouped = FixtureConnection(name: "b", groupId: group.id)

        let changes = LibraryProjectNormalizer.deletingProject(
            acme, connections: [loose, grouped], groups: [group, other]
        )

        #expect(changes.connections == [loose.id: nil])
        #expect(changes.groups == [group.id: nil])
    }

    @Test("A form save stores a project only on an ungrouped connection and a top-level group")
    func formSave() {
        let group = FixtureGroup(name: "G")
        #expect(LibraryProjectNormalizer.connectionProjectId(acme, groupId: group.id, groups: [group]) == nil)
        #expect(LibraryProjectNormalizer.connectionProjectId(acme, groupId: nil, groups: [group]) == acme)
        #expect(LibraryProjectNormalizer.connectionProjectId(acme, groupId: UUID(), groups: [group]) == acme)
        #expect(LibraryProjectNormalizer.groupProjectId(acme, parentId: group.id, groups: [group]) == nil)
        #expect(LibraryProjectNormalizer.groupProjectId(acme, parentId: nil, groups: [group]) == acme)
    }
}

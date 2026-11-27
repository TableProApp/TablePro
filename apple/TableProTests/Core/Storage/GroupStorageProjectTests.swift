import Combine
import Foundation
@testable import TablePro
import TableProImport
import TableProSyncTransport
import Testing

@MainActor
struct GroupStorageProjectTests {
    private let fixture: ProjectLibraryFixture
    private var groups: GroupStorage { fixture.groups }

    init() throws {
        fixture = try ProjectLibraryFixture()
    }

    // MARK: - Names

    @Test("Two projects can each hold a top-level group of one name, and one project cannot")
    func topLevelNamesAreUniquePerProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")

        try fixture.addGroup("Production", projectId: acme.id)
        try fixture.addGroup("Production", projectId: globex.id)
        try fixture.addGroup("Production")

        #expect(throws: GroupStorageError.duplicateName("production")) {
            try fixture.addGroup("production", projectId: acme.id)
        }
        #expect(throws: GroupStorageError.duplicateName("PRODUCTION")) {
            try fixture.addGroup("PRODUCTION")
        }
        #expect(groups.loadGroups().count == 3)
    }

    @Test("A rename is checked against the groups of the same project only")
    func renameChecksOneProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        try fixture.addGroup("Production", projectId: acme.id)
        let staging = try fixture.addGroup("Staging", projectId: acme.id)
        let other = try fixture.addGroup("Staging", projectId: globex.id)

        try groups.mutateGroup(id: other.id) { $0.name = "Production" }
        #expect(throws: GroupStorageError.duplicateName("Production")) {
            try groups.mutateGroup(id: staging.id) { $0.name = "Production" }
        }
    }

    @Test("A nested group stores no project of its own")
    func nestedGroupStoresNoProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let production = try fixture.addGroup("Production", projectId: acme.id)

        let europe = try fixture.addGroup("Europe", parentId: production.id, projectId: acme.id)

        #expect(europe.projectId == nil)
    }

    // MARK: - Moves

    @Test("A group moved to the top level keeps the project of the group it left")
    func groupMovedToRootKeepsItsProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let production = try fixture.addGroup("Production", projectId: acme.id)
        let europe = try fixture.addGroup("Europe", parentId: production.id)

        try groups.moveGroups([europe.id], toParent: nil, before: nil)

        #expect(groups.group(for: europe.id)?.parentId == nil)
        #expect(groups.group(for: europe.id)?.projectId == acme.id)
    }

    @Test("A top-level group moved under another drops its own project")
    func groupMovedUnderAnotherDropsItsProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let production = try fixture.addGroup("Production", projectId: acme.id)
        let staging = try fixture.addGroup("Staging", projectId: globex.id)

        try groups.moveGroups([staging.id], toParent: production.id, before: nil)

        #expect(groups.group(for: staging.id)?.projectId == nil)
    }

    @Test("A move to the top level is refused when the project the group stays in has that name")
    func moveToRootChecksTheProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let production = try fixture.addGroup("Production", projectId: acme.id)
        let nested = try fixture.addGroup("Staging", parentId: production.id)
        try fixture.addGroup("Staging", projectId: globex.id)

        try groups.moveGroups([nested.id], toParent: nil, before: nil)
        #expect(groups.group(for: nested.id)?.projectId == acme.id)

        let again = try fixture.addGroup("Staging", parentId: production.id)
        #expect(throws: GroupStorageError.duplicateName("Staging")) {
            try groups.moveGroups([again.id], toParent: nil, before: nil)
        }
    }

    @Test("Two groups of one name moved to a project together are refused, and neither moves")
    func batchMoveToProjectChecksIncomingNamesAgainstEachOther() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let initech = try fixture.projects.createProject(name: "Initech")
        let first = try fixture.addGroup("Production", projectId: acme.id)
        let second = try fixture.addGroup("production ", projectId: globex.id)
        let before = groups.loadGroups()

        #expect(throws: GroupStorageError.duplicateName("production ")) {
            try groups.moveGroups([first.id, second.id], toProject: initech.id)
        }
        #expect(groups.loadGroups() == before)

        let nested = try fixture.addGroup("Production", parentId: try fixture.addGroup("Europe", projectId: acme.id).id)
        #expect(throws: GroupStorageError.duplicateName("Production")) {
            try groups.moveGroups([first.id, nested.id], toProject: initech.id)
        }

        try groups.moveGroups([first.id], toProject: initech.id)
        #expect(groups.group(for: first.id)?.projectId == initech.id)
    }

    @Test("Two groups of one name moved under one parent together are refused, and neither moves")
    func batchMoveToParentChecksIncomingNamesAgainstEachOther() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let target = try fixture.addGroup("Shared")
        let first = try fixture.addGroup("Production", projectId: acme.id)
        let second = try fixture.addGroup("Production", projectId: globex.id)
        let before = groups.loadGroups()

        #expect(throws: GroupStorageError.duplicateName("Production")) {
            try groups.moveGroups([first.id, second.id], toParent: target.id, before: nil)
        }
        #expect(groups.loadGroups() == before)
    }

    @Test("Groups of one name moved to the top level together are refused only when they land in one project")
    func batchMoveToRootChecksEachProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let acmeRoot = try fixture.addGroup("Production", projectId: acme.id)
        let globexRoot = try fixture.addGroup("Production", projectId: globex.id)
        let acmeEurope = try fixture.addGroup("Europe", parentId: acmeRoot.id)
        let globexEurope = try fixture.addGroup("Europe", parentId: globexRoot.id)
        let acmeOther = try fixture.addGroup("Other", projectId: acme.id)
        let acmeEuropeAgain = try fixture.addGroup("Europe", parentId: acmeOther.id)

        #expect(throws: GroupStorageError.duplicateName("Europe")) {
            try groups.moveGroups([acmeEurope.id, acmeEuropeAgain.id], toParent: nil, before: nil)
        }
        #expect(groups.group(for: acmeEurope.id)?.parentId == acmeRoot.id)

        try groups.moveGroups([acmeEurope.id, globexEurope.id], toParent: nil, before: nil)
        #expect(groups.group(for: acmeEurope.id)?.projectId == acme.id)
        #expect(groups.group(for: globexEurope.id)?.projectId == globex.id)
    }

    // MARK: - Restoring a placement

    @Test("A placement is restored across projects with its parent, project and order, in one write")
    func restorePlacementAcrossProjects() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let staging = try fixture.addGroup("Staging", projectId: acme.id)
        try fixture.addGroup("Staging", projectId: globex.id)
        let production = try fixture.addGroup("Production", projectId: globex.id)
        try groups.moveGroups([staging.id], toParent: production.id, before: nil)
        #expect(groups.group(for: staging.id)?.projectId == nil)
        var announced = 0
        let subscription = fixture.appEvents.connectionUpdated.sink { _ in announced += 1 }
        defer { subscription.cancel() }

        try groups.restorePlacements([
            staging.id: ConnectionGroupPlacement(parentId: nil, projectId: acme.id, sortOrder: staging.sortOrder),
        ])

        let restored = try #require(groups.group(for: staging.id))
        #expect(restored.parentId == nil)
        #expect(restored.projectId == acme.id)
        #expect(restored.sortOrder == staging.sortOrder)
        #expect(announced == 1)
    }

    @Test("A restore that one group cannot take changes none of them")
    func restorePlacementIsAllOrNothing() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let staging = try fixture.addGroup("Staging", projectId: acme.id)
        let europe = try fixture.addGroup("Europe", projectId: acme.id)
        let production = try fixture.addGroup("Production", projectId: globex.id)
        try groups.moveGroups([staging.id, europe.id], toParent: production.id, before: nil)
        try fixture.addGroup("Staging", projectId: acme.id)
        let before = groups.loadGroups()

        #expect(throws: GroupStorageError.duplicateName("Staging")) {
            try groups.restorePlacements([
                europe.id: ConnectionGroupPlacement(parentId: nil, projectId: acme.id, sortOrder: europe.sortOrder),
                staging.id: ConnectionGroupPlacement(parentId: nil, projectId: acme.id, sortOrder: staging.sortOrder),
            ])
        }
        #expect(groups.loadGroups() == before)
    }

    @Test("A restore under a group that is gone, into a cycle or past the nesting limit is refused")
    func restorePlacementChecksTheHierarchy() throws {
        let a = try fixture.addGroup("A")
        let b = try fixture.addGroup("B", parentId: a.id)
        let c = try fixture.addGroup("C", parentId: b.id)
        let d = try fixture.addGroup("D")

        #expect(throws: GroupStorageError.groupNotFound) {
            try groups.restorePlacements([d.id: ConnectionGroupPlacement(parentId: UUID(), projectId: nil, sortOrder: 0)])
        }
        #expect(throws: GroupStorageError.wouldCreateCycle) {
            try groups.restorePlacements([a.id: ConnectionGroupPlacement(parentId: c.id, projectId: nil, sortOrder: 0)])
        }
        #expect(throws: GroupStorageError.depthExceeded) {
            try groups.restorePlacements([d.id: ConnectionGroupPlacement(parentId: c.id, projectId: nil, sortOrder: 0)])
        }
        #expect(groups.group(for: d.id)?.parentId == nil)
    }

    @Test("The edit sheet's move to the top level keeps the project too")
    func editSheetMoveKeepsTheProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let production = try fixture.addGroup("Production", projectId: acme.id)
        let europe = try fixture.addGroup("Europe", parentId: production.id)

        try groups.editGroup(
            id: europe.id,
            from: ConnectionGroupFields(europe),
            to: ConnectionGroupFields(name: "Europe", parentId: nil)
        )

        #expect(groups.group(for: europe.id)?.projectId == acme.id)
    }

    @Test("A connection moved into a group drops its own project, and moved out keeps the group's")
    func connectionMoves() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let production = try fixture.addGroup("Production", projectId: acme.id)
        let connection = fixture.addConnection("a", projectId: globex.id)

        #expect(fixture.connections.moveConnections(
            [connection.id], toGroup: production.id, before: nil, groups: groups.loadGroups()
        ))
        #expect(fixture.stored(connection)?.projectId == nil)
        #expect(fixture.scope.projectId(ofConnection: connection.id) == acme.id)

        #expect(fixture.connections.moveConnections(
            [connection.id], toGroup: nil, before: nil, groups: groups.loadGroups()
        ))
        #expect(fixture.stored(connection)?.groupId == nil)
        #expect(fixture.stored(connection)?.projectId == acme.id)
    }

    @Test("A copy of a connection stays in the source's project")
    func duplicateKeepsTheProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let connection = fixture.addConnection("a", projectId: acme.id)

        let copy = try #require(fixture.connections.duplicateConnection(connection))

        #expect(fixture.stored(copy)?.projectId == acme.id)
    }

    // MARK: - Delete

    @Test("Deleting a group ungroups its connections, a Local only one too, and keeps them in its project")
    func deleteClearsMembers() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let production = try fixture.addGroup("Production", projectId: acme.id)
        let europe = try fixture.addGroup("Europe", parentId: production.id)
        let synced = fixture.addConnection("synced", groupId: production.id)
        let localOnly = fixture.addConnection("local", groupId: europe.id, localOnly: true)
        fixture.clearDirty()

        #expect(groups.deleteGroup(production))

        #expect(groups.loadGroups().isEmpty)
        for connection in [synced, localOnly] {
            #expect(fixture.stored(connection)?.groupId == nil)
            #expect(fixture.stored(connection)?.projectId == acme.id)
        }
        #expect(fixture.tombstones(.group) == [production.id.uuidString, europe.id.uuidString])
        #expect(fixture.dirty(.connection) == [synced.id.uuidString])
    }

    @Test("A group whose connections cannot be saved stays, reports the failure and sends no tombstone")
    func deleteReportsAFailedMemberUpdate() throws {
        let group = try fixture.addGroup("Production")
        fixture.addConnection("member", groupId: group.id)
        try LibraryWriteRefusal.set(true, in: fixture.directory)
        defer { try? LibraryWriteRefusal.set(false, in: fixture.directory) }

        #expect(!groups.deleteGroup(group))

        #expect(groups.group(for: group.id) != nil)
        #expect(fixture.tombstones(.group).isEmpty)
    }

    // MARK: - Import paths

    @Test("An imported path reuses a top-level group only inside the project it names")
    func ensureGroupPathsMatchesInsideOneProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let existing = try fixture.addGroup("Production", projectId: acme.id)

        let leaves = try groups.ensureGroupPaths([
            [PathComponent(name: "Production", scope: acme.id, color: nil)],
            [PathComponent(name: "Production", scope: globex.id, color: nil),
             PathComponent(name: "Europe", scope: nil, color: nil)],
            [PathComponent(name: "Production", scope: nil, color: nil)],
        ])

        #expect(leaves[0] == existing.id)
        let europe = try #require(leaves[1].flatMap { groups.group(for: $0) })
        let globexRoot = try #require(europe.parentId.flatMap { groups.group(for: $0) })
        #expect(europe.projectId == nil)
        #expect(globexRoot.id != existing.id)
        #expect(globexRoot.projectId == globex.id)
        let unfiled = try #require(leaves[2].flatMap { groups.group(for: $0) })
        #expect(unfiled.projectId == nil)
        #expect(unfiled.id != existing.id)
        #expect(groups.loadGroups().count == 4)
    }
}

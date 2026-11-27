import Combine
import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProSyncTransport
import TableProTestSupport
import Testing

@MainActor
struct ConnectionScopeTests {
    private let fixture: ProjectLibraryFixture
    private var scope: ConnectionScope { fixture.scope }

    init() throws {
        fixture = try ProjectLibraryFixture()
    }

    @Test("All Connections lists the whole library and allows every connection id")
    func allConnections() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let inProject = fixture.addConnection("a", projectId: acme.id)
        let loose = fixture.addConnection("b")

        #expect(scope.activeProjectId == nil)
        #expect(scope.current.projectId == nil)
        #expect(scope.connections.map(\.id) == [inProject.id, loose.id])
        #expect(scope.allowedConnectionIds == nil)
        #expect(scope.contains(connectionId: UUID()))
    }

    @Test("An active project lists its own connections, through a top-level group for the grouped ones")
    func activeProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let production = try fixture.addGroup("Production", projectId: acme.id)
        let europe = try fixture.addGroup("Europe", parentId: production.id)
        let other = try fixture.addGroup("Production", projectId: globex.id)
        let nested = fixture.addConnection("nested", groupId: europe.id)
        let loose = fixture.addConnection("loose", projectId: acme.id)
        let elsewhere = fixture.addConnection("elsewhere", groupId: other.id)
        let unfiled = fixture.addConnection("unfiled")

        scope.setActiveProject(acme.id)

        #expect(scope.activeProjectId == acme.id)
        #expect(scope.current.projectId == acme.id)
        #expect(scope.connectionIds == [nested.id, loose.id])
        #expect(Set(scope.groups.map(\.id)) == [production.id, europe.id])
        #expect(scope.allowedConnectionIds == [nested.id, loose.id])
        #expect(!scope.contains(connectionId: elsewhere.id))
        #expect(!scope.contains(connectionId: unfiled.id))
        #expect(scope.projectId(ofConnection: nested.id) == acme.id)
        #expect(scope.projectId(ofConnection: elsewhere.id) == globex.id)
    }

    @Test("A lookup by id still finds a connection outside the active project")
    func lookupByIdIsUnscoped() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let outside = fixture.addConnection("outside")
        scope.setActiveProject(acme.id)

        #expect(scope.connections.isEmpty)
        #expect(fixture.connections.loadConnection(id: outside.id) != nil)
        #expect(fixture.connections.loadConnections().map(\.id) == [outside.id])
    }

    @Test("An active project that no longer exists reads as All Connections")
    func unknownActiveProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let connection = fixture.addConnection("a", projectId: acme.id)
        let unfiled = fixture.addConnection("b")
        scope.setActiveProject(acme.id)

        try fixture.projects.deleteProject(id: acme.id)

        #expect(scope.storedActiveProjectId == acme.id)
        #expect(scope.activeProjectId == nil)
        #expect(scope.allowedConnectionIds == nil)
        #expect(scope.connectionIds == [connection.id, unfiled.id])
    }

    @Test("A connection naming a project this Mac does not hold keeps the id and reads as in no project")
    func unknownProjectIdIsKept() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let arrivesLater = UUID()
        let connection = fixture.addConnection("a", projectId: arrivesLater)
        scope.setActiveProject(acme.id)

        #expect(scope.connections.isEmpty)
        #expect(scope.projectId(ofConnection: connection.id) == nil)
        #expect(fixture.stored(connection)?.projectId == arrivesLater)

        // As a pull writes it into the library.
        #expect(fixture.projects.saveProjects(fixture.projects.loadProjects() + [ConnectionProject(id: arrivesLater, name: "Late")]))
        scope.setActiveProject(arrivesLater)
        #expect(scope.connectionIds == [connection.id])
    }

    @Test("The list follows storage on every read")
    func readsStorageEachTime() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        scope.setActiveProject(acme.id)
        #expect(scope.connections.isEmpty)

        let added = fixture.addConnection("a", projectId: acme.id)
        #expect(scope.connectionIds == [added.id])

        #expect(fixture.projects.moveConnections([added.id], toProject: nil))
        #expect(scope.connections.isEmpty)
    }

    @Test("A switch is stored on this Mac and announced once, and choosing the same project again is silent")
    func switchAnnounces() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        var count = 0
        let subscription = scope.scopedSetChanged.sink { count += 1 }
        defer { subscription.cancel() }

        scope.setActiveProject(acme.id)
        scope.setActiveProject(acme.id)
        #expect(count == 1)
        #expect(fixture.defaults.string(forKey: ConnectionScope.activeProjectKey) == acme.id.uuidString)

        scope.setActiveProject(nil)
        #expect(count == 2)
        #expect(fixture.defaults.object(forKey: ConnectionScope.activeProjectKey) == nil)
        #expect(fixture.dirty(.project) == [acme.id.uuidString])
    }

    @Test("A new connection or top-level group lands in the active project, and a nested one stores none")
    func newRecordsLandInTheActiveProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let production = try fixture.addGroup("Production", projectId: acme.id)
        scope.setActiveProject(acme.id)

        #expect(scope.placingInActiveProject(DatabaseConnection(name: "loose")).projectId == acme.id)
        #expect(scope.placingInActiveProject(DatabaseConnection(name: "grouped", groupId: production.id)).projectId == nil)
        #expect(scope.placingInActiveProject(ConnectionGroup(name: "Staging")).projectId == acme.id)
        #expect(scope.placingInActiveProject(ConnectionGroup(name: "Europe", parentId: production.id)).projectId == nil)

        scope.setActiveProject(nil)
        #expect(scope.placingInActiveProject(DatabaseConnection(name: "loose")).projectId == nil)
    }

    // MARK: - Scope signal

    @Test("The scope signal fires once for each change to what is in scope")
    func signalFiresOncePerChange() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let production = try fixture.addGroup("Production", projectId: globex.id)
        let staging = try fixture.addGroup("Staging", projectId: acme.id)
        let loose = fixture.addConnection("loose")
        let grouped = fixture.addConnection("grouped", groupId: production.id)
        let member = fixture.addConnection("member", projectId: acme.id)
        fixture.appEvents.connectionUpdated.send(nil)
        var count = 0
        let subscription = scope.scopedSetChanged.sink { count += 1 }
        defer { subscription.cancel() }

        scope.setActiveProject(acme.id)
        #expect(count == 1)
        #expect(scope.connectionIds == [member.id])

        #expect(fixture.projects.moveConnections([loose.id], toProject: acme.id))
        #expect(count == 2)

        try fixture.projects.moveGroups([production.id], toProject: acme.id)
        #expect(count == 3)
        #expect(scope.connectionIds == [member.id, loose.id, grouped.id])

        try fixture.projects.moveGroups([production.id], toProject: globex.id)
        #expect(count == 4)

        #expect(fixture.connections.moveConnections(
            [loose.id], toGroup: production.id, before: nil, groups: fixture.groups.loadGroups()
        ))
        #expect(count == 5)
        #expect(scope.connectionIds == [member.id])

        #expect(fixture.groups.deleteGroup(staging))
        #expect(count == 6)

        let imported = DatabaseConnection(name: "imported", projectId: acme.id)
        #expect(fixture.connections.applyImport(adding: [imported], replacing: []) != nil)
        #expect(count == 7)
        #expect(scope.connectionIds == [member.id, imported.id])
    }

    @Test("Deleting the active project, here or by a pull, sends the signal and reads as All Connections")
    func signalFollowsADeletedProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let member = fixture.addConnection("member", projectId: acme.id)
        let other = fixture.addConnection("other", projectId: globex.id)
        fixture.appEvents.connectionUpdated.send(nil)
        scope.setActiveProject(acme.id)
        var snapshots: [ConnectionScopeSnapshot] = []
        let subscription = scope.scopedSetChanged.sink { [scope] in snapshots.append(scope.snapshot) }
        defer { subscription.cancel() }

        try fixture.projects.deleteProject(id: acme.id)
        #expect(snapshots.last?.projectId == nil)
        #expect(snapshots.last?.connectionIds == [member.id, other.id])
        #expect(Set(snapshots).count == snapshots.count, "Each send carries a scope the last one did not")

        scope.setActiveProject(globex.id)
        let beforePull = snapshots.count
        // A pull applies the deletion, then announces the library once.
        #expect(fixture.projects.saveProjects(fixture.projects.loadProjects().filter { $0.id != globex.id }))
        #expect(snapshots.count == beforePull)
        fixture.appEvents.connectionUpdated.send(nil)
        #expect(snapshots.count == beforePull + 1)
        #expect(scope.allowedConnectionIds == nil)
    }

    @Test("A library edit that leaves the scope as it was sends no signal")
    func signalIgnoresUnrelatedEdits() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let member = fixture.addConnection("member", projectId: acme.id)
        let outside = fixture.addConnection("outside", projectId: globex.id)
        fixture.appEvents.connectionUpdated.send(nil)
        scope.setActiveProject(acme.id)
        var count = 0
        let subscription = scope.scopedSetChanged.sink { count += 1 }
        defer { subscription.cancel() }

        #expect(fixture.connections.mutateConnections(ids: [member.id]) { $0.name = "renamed" })
        #expect(fixture.connections.mutateConnections(ids: [outside.id]) { $0.host = "db.example.com" })
        try fixture.projects.renameProject(id: acme.id, to: "Acme Corp")
        try fixture.projects.createProject(name: "Initech")
        try fixture.addGroup("Elsewhere", projectId: globex.id)
        fixture.addConnection("another outside", projectId: globex.id)
        fixture.appEvents.connectionUpdated.send(nil)
        fixture.appEvents.connectionUpdated.send(member.id)
        scope.setActiveProject(acme.id)

        #expect(count == 0)
    }

    @available(macOS 14.0, *)
    @Test("The Shortcuts parameters are refreshed on a scope change as on a library change")
    func shortcutParametersFollowTheScope() async throws {
        let scopeChanged = PassthroughSubject<Void, Never>()
        var updates = 0
        let refresher = ShortcutsParameterRefresher()
        refresher.start(
            appEvents: fixture.appEvents,
            scopeChanged: scopeChanged.eraseToAnyPublisher(),
            debounce: .milliseconds(10),
            update: { updates += 1 }
        )
        #expect(updates == 1)

        scopeChanged.send()
        try await waitUntil { updates == 2 }

        fixture.appEvents.connectionUpdated.send(nil)
        try await waitUntil { updates == 3 }
    }
}

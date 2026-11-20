import Foundation
@testable import TableProMobile
import TableProModels
import TableProSyncTransport
import Testing

@MainActor
struct AppStateProjectTests {
    private final class Recorder {
        var widgetFile: [WidgetConnectionItem] = []
        var shortcutRefreshes = 0
    }

    private let fixture: AppStateFixture
    private let recorder = Recorder()

    init() throws {
        fixture = try AppStateFixture()
    }

    private var projectsFile: URL {
        fixture.libraryDirectory.appendingPathComponent("projects.json")
    }

    private func makeState() -> AppState {
        let recorder = recorder
        return fixture.makeState(syncEnabled: false, libraryPublisher: ConnectionLibraryPublisher(
            searchIndex: RecordingSearchIndex(),
            readWidgetItems: { recorder.widgetFile },
            writeWidgetItems: { recorder.widgetFile = $0 },
            refreshShortcutParameters: { recorder.shortcutRefreshes += 1 },
            defaults: fixture.defaults
        ))
    }

    private func addProject(_ name: String, to state: AppState) throws -> UUID {
        guard case .applied(let id) = state.addProject(named: name) else {
            Issue.record("the project was not added")
            throw CancellationError()
        }
        return id
    }

    @Test("An install with no projects file has no projects and shows every connection")
    func oldInstallShowsEverything() {
        let state = makeState()
        #expect(state.addConnection(DatabaseConnection(name: "Orders", type: .mysql)))

        #expect(state.projects.isEmpty)
        #expect(state.areProjectsWritable)
        #expect(state.activeProject == nil)
        #expect(state.scopedConnections.map(\.name) == ["Orders"])
    }

    @Test("A damaged projects file reads as no projects, refuses project writes and leaves the library usable")
    func damagedProjectsFileDoesNotLockTheList() throws {
        try Data("not json".utf8).write(to: projectsFile)
        let state = makeState()

        #expect(state.loadStatus == .ready)
        #expect(state.projects.isEmpty)
        #expect(!state.areProjectsWritable)
        #expect(state.addProject(named: "Acme") == .refused)
        #expect(state.addConnection(DatabaseConnection(name: "Orders", type: .mysql)))
        #expect(state.scopedConnections.count == 1)
        #expect(try Data(contentsOf: projectsFile) == Data("not json".utf8))
    }

    @Test("Projects survive a relaunch, and a record this build cannot read stays in the file")
    func projectsPersist() throws {
        let unreadableId = UUID()
        try Data(#"[{"id":"\#(unreadableId.uuidString)","shape":2}]"#.utf8).write(to: projectsFile)
        let state = makeState()
        let id = try addProject("Acme", to: state)
        #expect(state.renameProject(id, to: "Acme Corp") == .applied(id))

        let relaunched = makeState()

        #expect(relaunched.projects.map(\.name) == ["Acme Corp"])
        #expect(relaunched.unreadableCopies.projects == [unreadableId])
    }

    @Test("The active project scopes the lists, and storage and lookups by id keep everything")
    func activeProjectScopes() throws {
        let state = makeState()
        let projectId = try addProject("Acme", to: state)
        let group = ConnectionGroup(name: "Production", projectId: projectId)
        let other = ConnectionGroup(name: "Internal")
        #expect(state.addGroup(group).isSaved)
        #expect(state.addGroup(other).isSaved)
        let grouped = DatabaseConnection(name: "Grouped", type: .mysql, groupId: group.id)
        let loose = DatabaseConnection(name: "Loose", type: .mysql, projectId: projectId)
        let outside = DatabaseConnection(name: "Outside", type: .mysql, groupId: other.id)
        for connection in [grouped, loose, outside] {
            #expect(state.addConnection(connection))
        }

        state.setActiveProject(projectId)

        #expect(Set(state.scopedConnections.map(\.id)) == [grouped.id, loose.id])
        #expect(state.scopedConnectionIds == [grouped.id, loose.id])
        #expect(state.scopedGroups.map(\.id) == [group.id])
        #expect(state.connections.count == 3)
        #expect(state.groups.count == 2)
        #expect(state.groupChoices(including: other.id).count == 2)
        #expect(state.groupChoices(including: group.id).map(\.id) == [group.id])
    }

    @Test("An active id no project holds reads as All Connections and is kept")
    func unknownActiveProjectFallsBack() {
        let state = makeState()
        let unknown = UUID()
        #expect(state.addConnection(DatabaseConnection(name: "Orders", type: .mysql, projectId: unknown)))

        state.setActiveProject(unknown)

        #expect(state.activeProjectId == nil)
        #expect(state.scopedConnections.count == 1)
        #expect(state.connections.first?.projectId == unknown)
        #expect(state.libraryPreferences.activeProjectId == unknown)
    }

    @Test("What the person makes lands in the active project, a copy keeps its source's, and the sample lands in none")
    func newThingsLandInTheActiveProject() throws {
        let state = makeState()
        let projectId = try addProject("Acme", to: state)
        let elsewhere = DatabaseConnection(name: "Elsewhere", type: .mysql)
        #expect(state.addConnection(elsewhere))
        state.setActiveProject(projectId)

        #expect(state.addConnectionToActiveProject(DatabaseConnection(name: "New", type: .mysql)))
        #expect(state.addGroupToActiveProject(ConnectionGroup(name: "Group")).isSaved)
        state.duplicateConnection(elsewhere)
        let sampleId = try state.openSampleDatabase()

        #expect(state.connections.first { $0.name == "New" }?.projectId == projectId)
        #expect(state.groups.first?.projectId == projectId)
        #expect(state.connections.first { $0.name == "Elsewhere Copy" }?.projectId == nil)
        #expect(state.connections.first { $0.id == sampleId }?.projectId == nil)
        #expect(state.scopedConnections.map(\.name) == ["New"])
    }

    @Test("Deleting the active project keeps its connections, clears their membership and returns to All Connections")
    func deletingTheActiveProject() throws {
        let state = makeState()
        let projectId = try addProject("Acme", to: state)
        let group = ConnectionGroup(name: "Production", projectId: projectId)
        #expect(state.addGroup(group).isSaved)
        #expect(state.addConnection(DatabaseConnection(name: "Loose", type: .mysql, projectId: projectId)))
        state.setActiveProject(projectId)

        state.deleteProject(projectId)

        #expect(state.projects.isEmpty)
        #expect(state.connections.map(\.projectId) == [nil])
        #expect(state.groups.map(\.projectId) == [nil])
        #expect(state.libraryPreferences.activeProjectId == nil)
        #expect(fixture.metadata.tombstones(for: .project).map(\.id) == [projectId.uuidString])
        #expect(fixture.metadata.dirtyIds(for: .group).contains(group.id.uuidString))
    }

    @Test("Move to Project moves an ungrouped connection and a top-level group, and marks them for upload")
    func moveToProject() throws {
        let state = makeState()
        let projectId = try addProject("Acme", to: state)
        let group = ConnectionGroup(name: "Production")
        #expect(state.addGroup(group).isSaved)
        let loose = DatabaseConnection(name: "Loose", type: .mysql)
        let grouped = DatabaseConnection(name: "Grouped", type: .mysql, groupId: group.id)
        #expect(state.addConnection(loose))
        #expect(state.addConnection(grouped))

        state.moveToProject(projectId, connections: [loose.id], groups: [group.id])
        state.setActiveProject(projectId)

        #expect(Set(state.scopedConnections.map(\.id)) == [loose.id, grouped.id])
        #expect(state.connections.first { $0.id == grouped.id }?.projectId == nil)
        #expect(fixture.metadata.dirtyIds(for: .project) == [projectId.uuidString])

        state.moveConnections([grouped.id], toGroup: nil)
        #expect(state.connections.first { $0.id == grouped.id }?.projectId == projectId)
    }

    @Test("Reordering projects renumbers them, and a duplicate name is refused")
    func reorderAndDuplicate() throws {
        let state = makeState()
        let first = try addProject("Acme", to: state)
        let second = try addProject("Internal", to: state)

        state.reorderProjects([second, first])

        #expect(state.orderedProjects.map(\.id) == [second, first])
        #expect(state.addProject(named: " acme ") == .duplicateName)
        #expect(state.renameProject(second, to: "ACME") == .duplicateName)
    }

    @Test("Reordering the favorites of the active project keeps the saved order of the other projects' favorites")
    func scopedFavoritesReorderKeepsOtherProjects() throws {
        let state = makeState()
        let acme = try addProject("Acme", to: state)
        let globex = try addProject("Globex", to: state)
        let favorite: (String, UUID) -> DatabaseConnection = { name, projectId in
            DatabaseConnection(name: name, type: .mysql, isFavorite: true, projectId: projectId)
        }
        let a1 = favorite("a1", acme), a2 = favorite("a2", acme)
        let b1 = favorite("b1", globex), b2 = favorite("b2", globex)
        for connection in [a1, a2, b1, b2] {
            #expect(state.addConnection(connection))
        }
        state.libraryPreferences.setFavoritesOrder([b1.id, a1.id, b2.id, a2.id])
        state.setActiveProject(acme)

        state.reorderFavorites([a2.id, a1.id])

        #expect(state.libraryPreferences.favoritesOrder == [b1.id, a2.id, b2.id, a1.id])

        state.setActiveProject(nil)
        state.reorderFavorites([a1.id, a2.id, b2.id, b1.id])
        #expect(state.libraryPreferences.favoritesOrder == [a1.id, a2.id, b2.id, b1.id])
    }

    @Test("The widget and Shortcuts get the active project's connections, again on every switch")
    func publisherFollowsTheActiveProject() throws {
        let state = makeState()
        let projectId = try addProject("Acme", to: state)
        let inside = DatabaseConnection(name: "Inside", type: .mysql, projectId: projectId)
        let outside = DatabaseConnection(name: "Outside", type: .mysql)
        #expect(state.addConnection(inside))
        #expect(state.addConnection(outside))
        #expect(Set(recorder.widgetFile.map(\.id)) == [inside.id, outside.id])
        let refreshes = recorder.shortcutRefreshes

        state.setActiveProject(projectId)
        #expect(recorder.widgetFile.map(\.id) == [inside.id])
        #expect(recorder.shortcutRefreshes == refreshes + 1)

        state.setActiveProject(projectId)
        #expect(recorder.shortcutRefreshes == refreshes + 1)

        state.moveToProject(projectId, connections: [outside.id], groups: [])
        #expect(Set(recorder.widgetFile.map(\.id)) == [inside.id, outside.id])

        state.deleteProject(projectId)
        #expect(Set(recorder.widgetFile.map(\.id)) == [inside.id, outside.id])
        state.setActiveProject(nil)
        #expect(recorder.widgetFile.count == 2)
    }

    @Test("The widget follows a group moved between projects, a group deleted and a connection moved between groups")
    func publisherFollowsMembershipChanges() throws {
        let state = makeState()
        let acme = try addProject("Acme", to: state)
        let globex = try addProject("Globex", to: state)
        let production = ConnectionGroup(name: "Production", projectId: acme)
        let staging = ConnectionGroup(name: "Staging", projectId: globex)
        #expect(state.addGroup(production).isSaved)
        #expect(state.addGroup(staging).isSaved)
        let grouped = DatabaseConnection(name: "Grouped", type: .mysql, groupId: production.id)
        let loose = DatabaseConnection(name: "Loose", type: .mysql, projectId: acme)
        #expect(state.addConnection(grouped))
        #expect(state.addConnection(loose))
        state.setActiveProject(acme)
        #expect(Set(recorder.widgetFile.map(\.id)) == [grouped.id, loose.id])

        state.moveToProject(globex, connections: [], groups: [production.id])
        #expect(recorder.widgetFile.map(\.id) == [loose.id])

        state.moveToProject(acme, connections: [], groups: [production.id])
        state.moveConnections([grouped.id], toGroup: staging.id)
        #expect(recorder.widgetFile.map(\.id) == [loose.id])

        state.moveConnections([grouped.id], toGroup: production.id)
        state.deleteGroup(production.id)
        #expect(Set(recorder.widgetFile.map(\.id)) == Set(state.scopedConnectionIds))
        #expect(recorder.widgetFile.map(\.id).contains(loose.id))
    }

    @Test("The widget follows a project and a connection a sync pull removes")
    func publisherFollowsAPull() throws {
        let state = makeState()
        state.connectSync()
        let acme = try addProject("Acme", to: state)
        let inside = DatabaseConnection(name: "Inside", type: .mysql, projectId: acme)
        let outside = DatabaseConnection(name: "Outside", type: .mysql)
        #expect(state.addConnection(inside))
        #expect(state.addConnection(outside))
        state.setActiveProject(acme)
        #expect(recorder.widgetFile.map(\.id) == [inside.id])

        // Another device deleted the active project, which reads as All Connections.
        #expect(state.syncCoordinator.onProjectsChanged?([]) == true)
        #expect(state.activeProjectId == nil)
        #expect(Set(recorder.widgetFile.map(\.id)) == [inside.id, outside.id])

        #expect(state.applySyncedConnections(state.connections.filter { $0.id != outside.id }))
        #expect(recorder.widgetFile.map(\.id) == [inside.id])
    }
}

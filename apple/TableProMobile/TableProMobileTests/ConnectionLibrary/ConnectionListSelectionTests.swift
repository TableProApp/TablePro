import Foundation
import TableProConnectionLibrary
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
struct ConnectionListSelectionTests {
    private let fixture: AppStateFixture

    init() throws {
        fixture = try AppStateFixture()
    }

    private func addProject(_ name: String, to state: AppState) throws -> UUID {
        guard case .applied(let id) = state.addProject(named: name) else {
            Issue.record("the project was not added")
            throw CancellationError()
        }
        return id
    }

    private func add(_ name: String, projectId: UUID? = nil, to state: AppState) -> UUID {
        let connection = DatabaseConnection(name: name, type: .mysql, projectId: projectId)
        #expect(state.addConnection(connection))
        return connection.id
    }

    private func selectedIds(_ selection: Set<LibraryRowID>, in state: AppState) -> Set<UUID> {
        Set(ConnectionListSelection.connectionIds(in: selection, scopedTo: state.scopedConnectionIds))
    }

    @Test("A row outside the scope leaves the selection, and a row inside it stays")
    func rowsOutsideTheScopeAreDropped() {
        let inside = UUID()
        let outside = UUID()
        let selection: Set<LibraryRowID> = [
            .connection(inside, section: .connections),
            .connection(outside, section: .connections),
            .connection(outside, section: .favorites),
        ]

        #expect(ConnectionListSelection.rows(selection, scopedTo: [inside]) == [.connection(inside, section: .connections)])
        #expect(ConnectionListSelection.connectionIds(in: selection, scopedTo: [inside]) == [inside])
        #expect(ConnectionListSelection.rows(selection, scopedTo: []).isEmpty)
        #expect(ConnectionListSelection.connectionIds(in: selection, scopedTo: []).isEmpty)
    }

    @Test("A sheet opened on some connections acts only on the ones still in the active project")
    func sheetFollowsAMoveMadeUnderIt() throws {
        let state = fixture.makeState(syncEnabled: false)
        let acme = try addProject("Acme", to: state)
        let globex = try addProject("Globex", to: state)
        let stays = add("stays", projectId: acme, to: state)
        let leaves = add("leaves", projectId: acme, to: state)
        state.setActiveProject(acme)
        let opened = [stays, leaves]
        #expect(ConnectionListSelection.connectionIds(opened, scopedTo: state.scopedConnectionIds) == opened)

        state.moveToProject(globex, connections: [leaves], groups: [])
        #expect(ConnectionListSelection.connectionIds(opened, scopedTo: state.scopedConnectionIds) == [stays])

        state.deleteProject(acme)
        #expect(ConnectionListSelection.connectionIds(opened, scopedTo: state.scopedConnectionIds) == opened)
    }

    @Test("The export sheet and the import choosers offer the scope in force when they are shown")
    func choosersFollowTheScope() throws {
        let state = fixture.makeState(syncEnabled: false)
        let acme = try addProject("Acme", to: state)
        let mine = add("mine", projectId: acme, to: state)
        let other = add("other", to: state)
        let localOnly = DatabaseConnection(name: "local", type: .sqlite, isSample: true, projectId: acme)
        #expect(state.addConnection(localOnly))
        func offered() -> [UUID] { ConnectionListSelection.openable(in: state.scopedConnections).map(\.id) }
        func exported() -> [UUID] { ConnectionListSelection.exportable(in: state.scopedConnections).map(\.id) }
        #expect(Set(offered()) == [mine, other, localOnly.id])

        state.setActiveProject(acme)
        #expect(Set(offered()) == [mine, localOnly.id])
        #expect(exported() == [mine])

        state.moveToProject(acme, connections: [other], groups: [])
        #expect(Set(offered()) == [mine, other, localOnly.id])
        #expect(Set(exported()) == [mine, other])

        state.deleteProject(acme)
        #expect(Set(exported()) == [mine, other])
    }

    @Test("The connection a file was opened over stays offered when it sits outside the active project")
    func openConnectionStaysOffered() throws {
        let state = fixture.makeState(syncEnabled: false)
        let acme = try addProject("Acme", to: state)
        let mine = add("mine", projectId: acme, to: state)
        let open = add("open", to: state)
        state.setActiveProject(acme)

        let offered = ConnectionListSelection.openable(in: state.scopedConnections, keeping: open, from: state.connections)
        #expect(offered.map(\.id) == [open, mine])
        let inScope = ConnectionListSelection.openable(in: state.scopedConnections, keeping: mine, from: state.connections)
        #expect(inScope.map(\.id) == [mine])
    }

    @Test("A connection selected in Favorites and in Connections is acted on once")
    func oneConnectionInTwoSections() {
        let id = UUID()
        let selection: Set<LibraryRowID> = [.connection(id, section: .favorites), .connection(id, section: .connections)]

        #expect(ConnectionListSelection.rows(selection, scopedTo: [id]) == selection)
        #expect(ConnectionListSelection.connectionIds(in: selection, scopedTo: [id]) == [id])
    }

    @Test("A selection made in one project is empty in another and in a project switch back")
    func projectSwitchClearsTheOtherProjectsRows() throws {
        let state = fixture.makeState(syncEnabled: false)
        let acme = try addProject("Acme", to: state)
        let globex = try addProject("Globex", to: state)
        let mine = add("mine", projectId: acme, to: state)
        let theirs = add("theirs", projectId: globex, to: state)
        state.setActiveProject(acme)
        let selection: Set<LibraryRowID> = [.connection(mine, section: .connections)]
        #expect(selectedIds(selection, in: state) == [mine])

        state.setActiveProject(globex)

        #expect(selectedIds(selection, in: state).isEmpty)
        #expect(ConnectionListSelection.rows(selection, scopedTo: state.scopedConnectionIds).isEmpty)
        #expect(state.scopedConnectionIds == [theirs])
    }

    @Test("A selected connection moved to another project leaves the selection, and the rest stay")
    func moveOutOfTheProject() throws {
        let state = fixture.makeState(syncEnabled: false)
        let acme = try addProject("Acme", to: state)
        let globex = try addProject("Globex", to: state)
        let moved = add("moved", projectId: acme, to: state)
        let kept = add("kept", projectId: acme, to: state)
        state.setActiveProject(acme)
        let selection: Set<LibraryRowID> = [
            .connection(moved, section: .connections),
            .connection(kept, section: .connections),
        ]

        state.moveToProject(globex, connections: [moved], groups: [])

        #expect(selectedIds(selection, in: state) == [kept])
    }

    @Test("A selected connection that was removed leaves the selection")
    func removedConnection() {
        let state = fixture.makeState(syncEnabled: false)
        let gone = add("gone", to: state)
        let kept = add("kept", to: state)
        let selection: Set<LibraryRowID> = [
            .connection(gone, section: .connections),
            .connection(kept, section: .connections),
        ]

        state.removeConnections([gone])

        #expect(selectedIds(selection, in: state) == [kept])
    }

    @Test("Search All Connections keeps a project's selection, since every row is still listed")
    func leavingTheProjectKeepsItsRows() throws {
        let state = fixture.makeState(syncEnabled: false)
        let acme = try addProject("Acme", to: state)
        let mine = add("mine", projectId: acme, to: state)
        _ = add("other", to: state)
        state.setActiveProject(acme)
        let selection: Set<LibraryRowID> = [.connection(mine, section: .connections)]

        state.setActiveProject(nil)

        #expect(selectedIds(selection, in: state) == [mine])
    }
}

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct ManageProjectsViewModelTests {
    private let fixture: ProjectLibraryFixture
    private let model: ManageProjectsViewModel

    init() throws {
        let fixture = try ProjectLibraryFixture()
        self.fixture = fixture
        model = ManageProjectsViewModel(storage: fixture.projects, appEvents: fixture.appEvents)
    }

    @Test("Add makes a project with a free name and selects it")
    func add() throws {
        let first = try #require(model.addProject())
        let second = try #require(model.addProject())

        #expect(model.projects.map(\.name) == ["New Project", "New Project 2"])
        #expect(model.projects.map(\.id) == [first, second])
        #expect(model.selection == second)
        #expect(fixture.projects.loadProjects().map(\.id) == [first, second])
        #expect(model.errorMessage == nil)
    }

    @Test("A rename is saved trimmed")
    func rename() throws {
        let id = try #require(model.addProject())

        #expect(model.rename(id, to: "  Acme  "))

        #expect(model.projects.map(\.name) == ["Acme"])
        #expect(model.errorMessage == nil)
    }

    @Test("An empty name and a name another project holds are refused, with the reason on show")
    func renameErrors() throws {
        try fixture.projects.createProject(name: "Acme")
        model.reload()
        let id = try #require(model.addProject())

        #expect(!model.rename(id, to: "   "))
        #expect(model.errorMessage == ProjectStorageError.emptyName.localizedDescription)

        #expect(!model.rename(id, to: "acme"))
        #expect(model.errorMessage == ProjectStorageError.duplicateName("acme").localizedDescription)
        #expect(model.projects.map(\.name) == ["Acme", "New Project"])

        #expect(model.rename(id, to: "Globex"))
        #expect(model.errorMessage == nil)
    }

    @Test("A drag reorders the projects in the store")
    func reorder() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let initech = try fixture.projects.createProject(name: "Initech")
        model.reload()

        model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(model.projects.map(\.id) == [initech.id, acme.id, globex.id])
        #expect(fixture.projects.loadProjects().map(\.id) == [initech.id, acme.id, globex.id])
    }

    @Test("Delete asks first, then removes the project and keeps its connections")
    func delete() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let connection = fixture.addConnection("a", projectId: acme.id)
        model.reload()
        model.selection = acme.id

        model.requestDeleteSelection()
        #expect(model.projectPendingDeletion?.id == acme.id)
        #expect(fixture.projects.loadProjects().count == 1)

        model.confirmDelete()

        #expect(model.projects.isEmpty)
        #expect(model.selection == nil)
        #expect(model.projectPendingDeletion == nil)
        #expect(fixture.stored(connection)?.projectId == nil)
        #expect(fixture.connections.loadConnections().map(\.id) == [connection.id])
    }

    @Test("A project made elsewhere reaches the list")
    func reloadsOnAChangeElsewhere() async throws {
        let acme = try fixture.projects.createProject(name: "Acme")

        try await waitUntil { model.projects.map(\.id) == [acme.id] }
    }
}

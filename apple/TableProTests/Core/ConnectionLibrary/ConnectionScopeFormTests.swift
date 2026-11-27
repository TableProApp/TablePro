import Combine
import Foundation
@testable import TablePro
import Testing

@MainActor
struct ConnectionScopeFormTests {
    private let fixture: ProjectLibraryFixture
    private var scope: ConnectionScope { fixture.scope }

    init() throws {
        fixture = try ProjectLibraryFixture()
    }

    @Test("A new connection and one inside the active project are offered the project's groups")
    func choicesInsideTheProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let inside = try fixture.addGroup("Inside", projectId: acme.id)
        try fixture.addGroup("Outside")
        let connection = fixture.addConnection("a", projectId: acme.id)
        scope.setActiveProject(acme.id)

        #expect(scope.groupChoices(forConnection: nil).map(\.id) == [inside.id])
        #expect(scope.groupChoices(forConnection: connection.id).map(\.id) == [inside.id])
    }

    @Test("A connection outside the active project is offered every group")
    func choicesOutsideTheProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let inside = try fixture.addGroup("Inside", projectId: acme.id)
        let outside = try fixture.addGroup("Outside")
        let connection = fixture.addConnection("a", groupId: outside.id)
        scope.setActiveProject(acme.id)

        #expect(Set(scope.groupChoices(forConnection: connection.id).map(\.id)) == [inside.id, outside.id])
    }

    @Test("In All Connections every group is offered")
    func choicesInAllConnections() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let inside = try fixture.addGroup("Inside", projectId: acme.id)
        let outside = try fixture.addGroup("Outside")

        #expect(Set(scope.groupChoices(forConnection: nil).map(\.id)) == [inside.id, outside.id])
    }

    @Test("A group made from the form lands in the active project, or in the project of a connection outside it")
    func newGroupPlacement() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let inside = fixture.addConnection("inside", projectId: acme.id)
        let outside = fixture.addConnection("outside", projectId: globex.id)
        scope.setActiveProject(acme.id)

        #expect(scope.placing(ConnectionGroup(name: "New"), forConnection: nil).projectId == acme.id)
        #expect(scope.placing(ConnectionGroup(name: "New"), forConnection: inside.id).projectId == acme.id)
        #expect(scope.placing(ConnectionGroup(name: "New"), forConnection: outside.id).projectId == globex.id)
    }

    // MARK: - Scope signal

    @Test("The form's group pop-up follows a switch and a group moved to another project, and keeps a chosen group on show")
    func pickerChoicesFollowTheScopeSignal() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let inside = try fixture.addGroup("Inside", projectId: acme.id)
        let outside = try fixture.addGroup("Outside", projectId: globex.id)
        var offered: [Set<UUID>] = []
        let subscription = scope.scopedSetChanged.sink { [fixture] in
            offered.append(Set(ConnectionGroupPicker.choices(
                forConnection: nil, selected: nil, scope: fixture.scope, groupStorage: fixture.groups
            ).map(\.id)))
        }
        defer { subscription.cancel() }

        scope.setActiveProject(acme.id)
        #expect(offered.last == [inside.id])

        try fixture.projects.moveGroups([outside.id], toProject: acme.id)
        #expect(offered.last == [inside.id, outside.id])

        try fixture.projects.moveGroups([inside.id], toProject: globex.id)
        #expect(offered.last == [outside.id])
        let keepsChosen = ConnectionGroupPicker.choices(
            forConnection: nil, selected: inside.id, scope: scope, groupStorage: fixture.groups
        )
        #expect(Set(keepsChosen.map(\.id)) == [inside.id, outside.id])
    }

    @Test("An endpoint picker open on a connection that left the list goes back to the connections")
    func endpointPickerPathFollowsTheList() {
        let listed = UUID()
        let gone = UUID()
        let onListed: [DatabaseEndpointRoute] = [.databases(listed)]
        let onGone: [DatabaseEndpointRoute] = [.databases(listed), .databases(gone)]

        #expect(DatabaseEndpointRoute.path(onListed, listing: [listed]) == onListed)
        #expect(DatabaseEndpointRoute.path(onGone, listing: [listed]).isEmpty)
        #expect(DatabaseEndpointRoute.path([], listing: []).isEmpty)
    }
}

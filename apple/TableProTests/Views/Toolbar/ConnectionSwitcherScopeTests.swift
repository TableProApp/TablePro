import Combine
import Foundation
@testable import TablePro
import Testing

@MainActor
struct ConnectionSwitcherScopeTests {
    private let fixture: ProjectLibraryFixture

    init() throws {
        fixture = try ProjectLibraryFixture()
    }

    private func listed() -> [UUID] {
        ConnectionSwitcherSections.listedSaved(
            fixture.connections.loadConnections(),
            groups: fixture.groups.loadGroups(),
            scope: fixture.scope
        ).map(\.id)
    }

    @Test("The saved rows are the active project's, and every connection in All Connections")
    func savedRowsFollowTheProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let production = try fixture.addGroup("Production", projectId: acme.id)
        let grouped = fixture.addConnection("grouped", groupId: production.id)
        let loose = fixture.addConnection("loose", projectId: acme.id)
        let outside = fixture.addConnection("outside")

        #expect(listed() == [grouped.id, loose.id, outside.id])

        fixture.scope.setActiveProject(acme.id)

        #expect(listed() == [grouped.id, loose.id])
    }

    @Test("The connection on screen stays in the list when it sits outside the active project")
    func openConnectionOutsideTheProjectStaysListed() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let inside = fixture.addConnection("inside", projectId: acme.id)
        let current = fixture.addConnection("current")
        fixture.scope.setActiveProject(acme.id)
        let all = fixture.connections.loadConnections()

        let hosted = ConnectionSwitcherSections.hostedWithoutSession(
            workspaces: [(connectionId: current.id, connection: nil)],
            sessionIds: [],
            saved: all
        )
        let saved = ConnectionSwitcherSections.listedSaved(all, groups: [], scope: fixture.scope)
        let sections = ConnectionSwitcherSections.build(
            active: hosted.map { ConnectionSwitcherEntry(id: $0.id, connection: $0, isActive: true) },
            saved: saved,
            groups: [],
            isFiltering: false
        )

        #expect(hosted.map(\.id) == [current.id])
        #expect(sections.first?.items.map(\.id) == [current.id])
        #expect(sections.dropFirst().flatMap(\.items).map(\.id) == [inside.id])
    }

    @Test("Reloading on the scope signal lists the scope in force after a switch and after a move")
    func savedRowsFollowTheScopeSignal() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let mine = fixture.addConnection("mine", projectId: acme.id)
        let theirs = fixture.addConnection("theirs", projectId: globex.id)
        fixture.appEvents.connectionUpdated.send(nil)
        var reloads: [[UUID]] = []
        let subscription = fixture.scope.scopedSetChanged.sink { reloads.append(listed()) }
        defer { subscription.cancel() }

        fixture.scope.setActiveProject(acme.id)
        #expect(reloads == [[mine.id]])

        #expect(fixture.projects.moveConnections([theirs.id], toProject: acme.id))
        #expect(reloads.count == 2)
        #expect(Set(reloads[1]) == [mine.id, theirs.id])

        try fixture.projects.deleteProject(id: acme.id)
        #expect(Set(reloads.last ?? []) == [mine.id, theirs.id])
    }
}

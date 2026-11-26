import Foundation
@testable import TablePro
import TableProConnectionLibrary
import Testing

@MainActor
struct WelcomeProjectMenuSpecTests {
    private let acme = ConnectionProject(name: "Acme", sortOrder: 0)
    private let globex = ConnectionProject(name: "Globex", sortOrder: 1)

    private func context(
        rows: [LibraryRowID],
        connections: [DatabaseConnection] = [],
        groups: [ConnectionGroup] = [],
        projects: [ConnectionProject]
    ) -> WelcomeMenuContext {
        var resolved = WelcomeResolvedRows()
        let byId = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        for row in rows {
            switch row {
            case .section:
                resolved.hasSectionHeader = true
            case .group(let id):
                resolved.sections.insert(.connections)
                resolved.groupIds.append(id)
            case .connection(let id, let section):
                resolved.sections.insert(section)
                resolved.savedConnectionIds.append(id)
            }
        }
        return WelcomeMenuContext(
            rows: rows,
            resolved: resolved,
            connections: byId,
            groups: groups,
            linkedFolderConnectionIds: [],
            disconnectableConnectionIds: [],
            reconnectableConnectionIds: [],
            isSyncEnabled: false,
            isCompareSyncEnabled: false,
            canPublishToTeamCatalog: false,
            teamLibraryTeams: [],
            hasTeamLibraryConflicts: false,
            projects: projects
        )
    }

    private func moveEntries(_ sections: [WelcomeMenuSection]) -> [SidebarMenuEntry<WelcomeMenuCommand>]? {
        for item in sections.flatMap(\.items) {
            guard case .submenu(let title, let children) = item, title == "Move to Project" else { continue }
            return children.flatMap(\.items).compactMap { child in
                guard case .command(let entry) = child else { return nil }
                return entry
            }
        }
        return nil
    }

    private func row(_ connection: DatabaseConnection) -> LibraryRowID {
        .connection(connection.id, section: .connections)
    }

    @Test("An ungrouped connection lists None first, then the projects, with its own checked")
    func ungroupedConnection() throws {
        let connection = DatabaseConnection(name: "loose", projectId: globex.id)
        let entries = try #require(moveEntries(WelcomeMenuSpec.sections(for: context(
            rows: [row(connection)],
            connections: [connection],
            projects: [acme, globex]
        ))))

        #expect(entries.map(\.title) == ["None", "Acme", "Globex"])
        #expect(entries.map(\.isOn) == [false, false, true])
        #expect(entries.map(\.command) == [
            .moveToProject(connectionIds: [connection.id], groupIds: [], projectId: nil),
            .moveToProject(connectionIds: [connection.id], groupIds: [], projectId: acme.id),
            .moveToProject(connectionIds: [connection.id], groupIds: [], projectId: globex.id),
        ])
    }

    @Test("A connection in no project, or in one that is gone, has None checked")
    func noProjectChecksNone() throws {
        let loose = DatabaseConnection(name: "loose")
        let orphan = DatabaseConnection(name: "orphan", projectId: UUID())
        for connection in [loose, orphan] {
            let entries = try #require(moveEntries(WelcomeMenuSpec.sections(for: context(
                rows: [row(connection)],
                connections: [connection],
                projects: [acme]
            ))))
            #expect(entries.map(\.isOn) == [true, false])
        }
    }

    @Test("A grouped connection moves with its group, so it is not offered")
    func groupedConnectionIsNotOffered() {
        let group = ConnectionGroup(name: "Production", projectId: acme.id)
        let connection = DatabaseConnection(name: "grouped", groupId: group.id)
        let sections = WelcomeMenuSpec.sections(for: context(
            rows: [row(connection)],
            connections: [connection],
            groups: [group],
            projects: [acme]
        ))

        #expect(moveEntries(sections) == nil)
    }

    @Test("With no projects the submenu is left out")
    func noProjects() {
        let connection = DatabaseConnection(name: "loose")
        let sections = WelcomeMenuSpec.sections(for: context(
            rows: [row(connection)],
            connections: [connection],
            projects: []
        ))

        #expect(moveEntries(sections) == nil)
    }

    @Test("A top-level group is offered, and a subgroup is not")
    func groups() throws {
        let top = ConnectionGroup(name: "Production", projectId: acme.id)
        let child = ConnectionGroup(name: "Europe", parentId: top.id)

        let entries = try #require(moveEntries(WelcomeMenuSpec.sections(for: context(
            rows: [.group(top.id)],
            groups: [top, child],
            projects: [acme, globex]
        ))))
        #expect(entries.map(\.isOn) == [false, true, false])
        #expect(entries.last?.command == .moveToProject(connectionIds: [], groupIds: [top.id], projectId: globex.id))

        let childSections = WelcomeMenuSpec.sections(for: context(
            rows: [.group(child.id)],
            groups: [top, child],
            projects: [acme, globex]
        ))
        #expect(moveEntries(childSections) == nil)
    }

    @Test("Several ungrouped connections move together, with a check only when they share a project")
    func multipleConnections() throws {
        let first = DatabaseConnection(name: "a", projectId: acme.id)
        let second = DatabaseConnection(name: "b", projectId: acme.id)
        let third = DatabaseConnection(name: "c")

        let shared = try #require(moveEntries(WelcomeMenuSpec.sections(for: context(
            rows: [row(first), row(second)],
            connections: [first, second],
            projects: [acme, globex]
        ))))
        #expect(shared.map(\.isOn) == [false, true, false])
        #expect(shared.first?.command == .moveToProject(
            connectionIds: [first.id, second.id], groupIds: [], projectId: nil
        ))

        let mixed = try #require(moveEntries(WelcomeMenuSpec.sections(for: context(
            rows: [row(first), row(third)],
            connections: [first, third],
            projects: [acme, globex]
        ))))
        #expect(mixed.map(\.isOn) == [false, false, false])
    }

    @Test("A selection that holds a grouped connection is not offered")
    func selectionWithAGroupedConnection() {
        let group = ConnectionGroup(name: "Production", projectId: acme.id)
        let grouped = DatabaseConnection(name: "grouped", groupId: group.id)
        let loose = DatabaseConnection(name: "loose")
        let sections = WelcomeMenuSpec.sections(for: context(
            rows: [row(grouped), row(loose)],
            connections: [grouped, loose],
            groups: [group],
            projects: [acme]
        ))

        #expect(moveEntries(sections) == nil)
    }

    @Test("Several top-level groups, and groups with ungrouped connections, move together")
    func mixedSelection() throws {
        let first = ConnectionGroup(name: "Production", projectId: acme.id)
        let second = ConnectionGroup(name: "Staging", projectId: acme.id)
        let loose = DatabaseConnection(name: "loose", projectId: acme.id)

        let groupsOnly = try #require(moveEntries(WelcomeMenuSpec.sections(for: context(
            rows: [.group(first.id), .group(second.id)],
            groups: [first, second],
            projects: [acme, globex]
        ))))
        #expect(groupsOnly.last?.command == .moveToProject(
            connectionIds: [], groupIds: [first.id, second.id], projectId: globex.id
        ))

        let both = try #require(moveEntries(WelcomeMenuSpec.sections(for: context(
            rows: [.group(first.id), row(loose)],
            connections: [loose],
            groups: [first, second],
            projects: [acme, globex]
        ))))
        #expect(both.map(\.isOn) == [false, true, false])
        #expect(both.last?.command == .moveToProject(
            connectionIds: [loose.id], groupIds: [first.id], projectId: globex.id
        ))
    }
}

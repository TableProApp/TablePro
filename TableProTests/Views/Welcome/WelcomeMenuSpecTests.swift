//
//  WelcomeMenuSpecTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import Testing

@Suite("Welcome menu spec")
struct WelcomeMenuSpecTests {
    private func context(
        rows: [LibraryRowID],
        connections: [DatabaseConnection] = [],
        groups: [ConnectionGroup] = [],
        disconnectable: Set<UUID> = [],
        linkedFolders: Set<UUID> = [],
        isSyncEnabled: Bool = false
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
                if section.acceptsSavedConnections, byId[id] != nil {
                    resolved.savedConnectionIds.append(id)
                } else if !section.acceptsSavedConnections {
                    resolved.sharedConnectionIds.append(id)
                }
            }
        }
        return WelcomeMenuContext(
            rows: rows,
            resolved: resolved,
            connections: byId,
            groups: groups,
            linkedFolderConnectionIds: linkedFolders,
            disconnectableConnectionIds: disconnectable,
            isSyncEnabled: isSyncEnabled,
            canPublishToTeamCatalog: false,
            canPublishToTeamLibrary: false
        )
    }

    private func titles(_ sections: [WelcomeMenuSection]) -> [[String]] {
        sections.map { section in section.items.map(title(of:)) }
    }

    private func title(of item: WelcomeMenuItem) -> String {
        switch item {
        case .command(let entry):
            return entry.title
        case .submenu(let title, _):
            return title
        }
    }

    private func submenu(_ title: String, in sections: [WelcomeMenuSection]) -> [WelcomeMenuSection]? {
        for section in sections {
            for item in section.items {
                if case .submenu(let itemTitle, let children) = item, itemTitle == title {
                    return children
                }
            }
        }
        return nil
    }

    @Test("Empty space offers creating and importing")
    func background() {
        let sections = WelcomeMenuSpec.sections(for: context(rows: []))
        #expect(titles(sections) == [["New Connection…", "New Group…"], ["Import"]])
    }

    @Test("A single connection in the tree offers the full set, with Delete last on its own")
    func singleConnection() {
        let connection = DatabaseConnection(name: "Prod", type: .mysql)
        let sections = WelcomeMenuSpec.sections(for: context(
            rows: [.connection(connection.id, section: .connections)],
            connections: [connection]
        ))
        let all = titles(sections)

        #expect(all.first == ["Connect"])
        #expect(all.last == ["Delete…"])
        #expect(all.flatMap { $0 }.contains("Rename"))
        #expect(all.flatMap { $0 }.contains("Move to Group"))
        #expect(!all.flatMap { $0 }.contains("Remove from Group"))
        #expect(!all.flatMap { $0 }.contains("Disconnect"))
        #expect(!all.flatMap { $0 }.contains("Exclude from iCloud Sync"))
    }

    @Test("Disconnect and iCloud appear only when they apply")
    func conditionalItems() {
        let connection = DatabaseConnection(name: "Prod", type: .mysql)
        let sections = WelcomeMenuSpec.sections(for: context(
            rows: [.connection(connection.id, section: .connections)],
            connections: [connection],
            disconnectable: [connection.id],
            isSyncEnabled: true
        ))
        let all = titles(sections).flatMap { $0 }

        #expect(all.contains("Disconnect"))
        #expect(all.contains("Exclude from iCloud Sync"))
    }

    @Test("A Favorites row names what Delete removes and offers removing the favorite")
    func favoritesRow() {
        var connection = DatabaseConnection(name: "Prod", type: .mysql)
        connection.isFavorite = true
        let sections = WelcomeMenuSpec.sections(for: context(
            rows: [.connection(connection.id, section: .favorites)],
            connections: [connection]
        ))
        let all = titles(sections)

        #expect(all.flatMap { $0 }.contains("Remove from Favorites"))
        #expect(all.last == ["Delete Connection…"])
    }

    @Test("A Recent row can be removed from Recent, and the header clears it")
    func recentRowAndHeader() {
        let connection = DatabaseConnection(name: "Prod", type: .mysql)
        let row = WelcomeMenuSpec.sections(for: context(
            rows: [.connection(connection.id, section: .recent)],
            connections: [connection]
        ))
        let header = WelcomeMenuSpec.sections(for: context(rows: [.section(.recent)]))

        #expect(titles(row).flatMap { $0 }.contains("Remove from Recent"))
        #expect(titles(header) == [["Clear Recent"]])
    }

    @Test("Move to Group checks the group a connection is in and indents nested groups")
    func moveToGroupMarksCurrent() throws {
        let parent = ConnectionGroup(name: "Acme")
        let child = ConnectionGroup(name: "Europe", parentId: parent.id)
        var connection = DatabaseConnection(name: "Prod", type: .mysql)
        connection.groupId = child.id
        let sections = WelcomeMenuSpec.sections(for: context(
            rows: [.connection(connection.id, section: .connections)],
            connections: [connection],
            groups: [parent, child]
        ))

        let move = try #require(submenu("Move to Group", in: sections))
        let entries = move[0].items.compactMap { item -> SidebarMenuEntry<WelcomeMenuCommand>? in
            guard case .command(let entry) = item else { return nil }
            return entry
        }
        #expect(entries.map(\.title) == ["Acme", "Europe"])
        #expect(entries.map(\.indentationLevel) == [0, 1])
        #expect(entries.map(\.isOn) == [false, true])
        #expect(titles(sections).flatMap { $0 }.contains("Remove from Group"))
    }

    @Test("A group at the nesting cap offers no New Subgroup")
    func groupAtCap() {
        let one = ConnectionGroup(name: "1")
        let two = ConnectionGroup(name: "2", parentId: one.id)
        let three = ConnectionGroup(name: "3", parentId: two.id)
        let groups = [one, two, three]

        let atCap = WelcomeMenuSpec.sections(for: context(rows: [.group(three.id)], groups: groups))
        let belowCap = WelcomeMenuSpec.sections(for: context(rows: [.group(one.id)], groups: groups))

        #expect(!titles(atCap).flatMap { $0 }.contains("New Subgroup…"))
        #expect(titles(belowCap).flatMap { $0 }.contains("New Subgroup…"))
        #expect(titles(atCap).last == ["Delete Group…"])
    }

    @Test("Several connections share one menu with counted titles")
    func multipleConnections() {
        let first = DatabaseConnection(name: "A", type: .mysql)
        let second = DatabaseConnection(name: "B", type: .mysql)
        let sections = WelcomeMenuSpec.sections(for: context(
            rows: [
                .connection(first.id, section: .connections),
                .connection(second.id, section: .connections),
            ],
            connections: [first, second]
        ))
        let all = titles(sections)

        #expect(all.first == ["Connect 2 Connections"])
        #expect(all.last == ["Delete 2 Connections…"])
    }

    @Test("A linked folder connection can be shown in Finder and nothing else is offered")
    func linkedConnection() {
        let id = UUID()
        let sections = WelcomeMenuSpec.sections(for: context(
            rows: [.connection(id, section: .linkedFolders)],
            linkedFolders: [id]
        ))

        #expect(titles(sections) == [["Connect"], ["Show in Finder"]])
    }
}

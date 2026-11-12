//
//  ConnectionNavigatorMenuTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import Testing

struct ConnectionNavigatorMenuTests {
    private let id = UUID()

    private func target(
        _ placement: ConnectionNavigatorPlacement,
        status: ConnectionDisplayStatus,
        holdsSession: Bool,
        canMoveToNewWindow: Bool = false
    ) -> ConnectionNavigatorMenuTarget {
        .connection(ConnectionNavigatorMenuConnection(
            id: id,
            placement: placement,
            status: status,
            holdsSession: holdsSession,
            canMoveToNewWindow: canMoveToNewWindow
        ))
    }

    private static func titles(_ sections: [ConnectionNavigatorMenuSection]) -> [[String]] {
        sections.map { section in
            section.items.map { item in
                switch item {
                case .command(let entry): return entry.title
                case .submenu(let title, _): return title
                }
            }
        }
    }

    private static func commands(_ sections: [ConnectionNavigatorMenuSection]) -> [ConnectionNavigatorCommand] {
        sections.flatMap { section in
            section.items.compactMap { item in
                guard case .command(let entry) = item else { return nil }
                return entry.command
            }
        }
    }

    @Test("A connected connection this window shows offers a new window, Disconnect and editing")
    func connectedAndShownHere() {
        let sections = ConnectionNavigatorMenu.sections(
            for: target(.shownHere, status: .connected, holdsSession: true, canMoveToNewWindow: true)
        )

        #expect(Self.titles(sections) == [
            ["Open in New Window", "Disconnect"],
            ["Edit Connection…", "Duplicate"],
            ["New Connection…", "New Group…"],
        ])
        #expect(Self.commands(sections) == [
            .openInNewWindow(id), .disconnect(id), .edit(id), .duplicate(id), .newConnection, .newGroup(parentId: nil),
        ])
    }

    @Test("A connection nobody has open offers Connect and a new window")
    func notConnectedNotOpen() {
        let sections = ConnectionNavigatorMenu.sections(for: target(.notOpen, status: .notConnected, holdsSession: false))

        #expect(Self.titles(sections).first == ["Connect", "Open in New Window"])
        #expect(Array(Self.commands(sections).prefix(2)) == [.open(id), .openInNewWindow(id)])
    }

    @Test("A connected session no window shows reads Open")
    func connectedButUnhostedReadsOpen() {
        let sections = ConnectionNavigatorMenu.sections(for: target(.notOpen, status: .connected, holdsSession: true))

        #expect(Self.titles(sections).first?.first == "Open")
        #expect(Self.commands(sections).first == .open(id))
    }

    @Test("A connection this window hosts but does not show offers Switch To")
    func openHereNotShown() {
        let sections = ConnectionNavigatorMenu.sections(for: target(.openHere, status: .connected, holdsSession: true))

        #expect(Self.titles(sections).first == ["Switch To", "Disconnect"])
        #expect(Self.commands(sections).first == .switchTo(id))
    }

    @Test("A connection open in another window offers Open and no new window")
    func openElsewhere() {
        let sections = ConnectionNavigatorMenu.sections(
            for: target(.openElsewhere, status: .connected, holdsSession: true, canMoveToNewWindow: true)
        )

        #expect(Self.titles(sections).first == ["Open", "Disconnect"])
        #expect(!Self.commands(sections).contains(.openInNewWindow(id)))
    }

    @Test("A group row creates a connection or a group inside it")
    func groupRow() {
        let groupId = UUID()
        let sections = ConnectionNavigatorMenu.sections(for: .group(groupId))

        #expect(Self.titles(sections) == [["New Connection…", "New Group…"]])
        #expect(Self.commands(sections) == [.newConnection, .newGroup(parentId: groupId)])
    }

    @Test("Empty space creates a connection or a top-level group")
    func emptySpace() {
        let sections = ConnectionNavigatorMenu.sections(for: .empty)

        #expect(Self.titles(sections) == [["New Connection…", "New Group…"]])
        #expect(Self.commands(sections) == [.newConnection, .newGroup(parentId: nil)])
    }

    @Test("Only New Connection carries a menu bar shortcut")
    func newConnectionShowsItsShortcut() {
        let others: [ConnectionNavigatorCommand] = [
            .switchTo(id), .open(id), .openInNewWindow(id), .disconnect(id), .edit(id), .duplicate(id),
            .newGroup(parentId: nil),
        ]
        #expect(ConnectionNavigatorCommand.newConnection.shortcutAction == .newConnection)
        for command in others {
            #expect(command.shortcutAction == nil)
        }
    }
}

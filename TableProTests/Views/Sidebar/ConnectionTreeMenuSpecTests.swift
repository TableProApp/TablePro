//
//  ConnectionTreeMenuSpecTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("ConnectionTreeMenuSpec")
struct ConnectionTreeMenuSpecTests {
    private let id = UUID()
    private let group = ConnectionGroup(name: "Production")

    private func commands(_ sections: [ConnectionTreeMenuSection]) -> [ConnectionTreeMenuCommand] {
        sections.flatMap { section in
            section.items.flatMap { item -> [ConnectionTreeMenuCommand] in
                switch item {
                case .command(let entry): return [entry.command]
                case .submenu(_, let nested): return commands(nested)
                }
            }
        }
    }

    @Test("A connection that is down offers Connect and not Disconnect")
    func downOffersConnect() {
        let found = commands(ConnectionTreeMenuSpec.sections(for: .init(clicked: .connection(id), status: .notConnected)))
        #expect(found.contains(.connect(id)))
        #expect(!found.contains(.disconnect(id)))
    }

    @Test("A connection that is up offers Disconnect and not Connect")
    func upOffersDisconnect() {
        let found = commands(ConnectionTreeMenuSpec.sections(for: .init(clicked: .connection(id), status: .connected)))
        #expect(found.contains(.disconnect(id)))
        #expect(!found.contains(.connect(id)))
    }

    /// A failed connection is offered a retry, not a disconnect: there is nothing to disconnect.
    @Test("A failed connection offers Connect")
    func failedOffersConnect() {
        let found = commands(ConnectionTreeMenuSpec.sections(for: .init(clicked: .connection(id), status: .failed)))
        #expect(found.contains(.connect(id)))
        #expect(!found.contains(.disconnect(id)))
    }

    /// Neither, while it is connecting. Both would name something that does not apply yet, and an
    /// item that does nothing is worse than an absent one.
    @Test("A connecting connection offers neither")
    func connectingOffersNeither() {
        let found = commands(ConnectionTreeMenuSpec.sections(for: .init(clicked: .connection(id), status: .connecting)))
        #expect(!found.contains(.connect(id)))
        #expect(!found.contains(.disconnect(id)))
    }

    @Test("Delete is the last command on a connection")
    func deleteIsLast() {
        let found = commands(ConnectionTreeMenuSpec.sections(for: .init(clicked: .connection(id), status: .connected)))
        #expect(found.last == .delete(id))
    }

    @Test("Move to Group lists every group except the one it is already in")
    func moveToGroupSkipsCurrent() {
        let other = ConnectionGroup(name: "Staging")
        let found = commands(ConnectionTreeMenuSpec.sections(for: .init(
            clicked: .connection(id), groups: [group, other], currentGroupId: group.id
        )))
        #expect(found.contains(.moveToGroup(connectionId: id, groupId: other.id)))
        #expect(!found.contains(.moveToGroup(connectionId: id, groupId: group.id)))
    }

    @Test("Remove from Group is offered only when it is in one")
    func removeFromGroupOnlyWhenGrouped() {
        let grouped = commands(ConnectionTreeMenuSpec.sections(for: .init(
            clicked: .connection(id), groups: [group], currentGroupId: group.id
        )))
        #expect(grouped.contains(.moveToGroup(connectionId: id, groupId: nil)))

        let loose = commands(ConnectionTreeMenuSpec.sections(for: .init(
            clicked: .connection(id), groups: [group], currentGroupId: nil
        )))
        #expect(!loose.contains(.moveToGroup(connectionId: id, groupId: nil)))
    }

    /// The count the user sees, not the count the spec emits. `Array.nonEmptySections()` drops an
    /// empty group before the builder rules between them, which is what lets a spec assemble a
    /// group out of items that may all turn out to be unavailable. Asserting on the raw array
    /// instead would forbid a shape the menu model deliberately allows.
    @Test("A connection with nowhere to be filed shows three groups, not four")
    func renderedGroupCount() {
        let loose = ConnectionTreeMenuSpec
            .sections(for: .init(clicked: .connection(id)))
            .nonEmptySections()
        #expect(loose.count == 3)

        let filed = ConnectionTreeMenuSpec
            .sections(for: .init(clicked: .connection(id), groups: [group], currentGroupId: group.id))
            .nonEmptySections()
        #expect(filed.count == 4)
    }

    /// The HIG asks for about three groups in a contextual menu, and the section model exists so a
    /// test can hold a spec to it rather than discovering five groups in the shipped menu.
    @Test("No menu grows past four groups")
    func noMenuGrowsPastFourGroups() {
        let shapes: [ConnectionTreeMenuContext] = [
            .init(clicked: nil),
            .init(clicked: .group(group)),
            .init(clicked: .connection(id), status: .connected, groups: [group], currentGroupId: group.id),
            .init(clicked: .connection(id), status: .connecting),
        ]
        for shape in shapes {
            #expect(ConnectionTreeMenuSpec.sections(for: shape).nonEmptySections().count <= 4)
        }
    }

    @Test("A folder offers rename and delete, with delete last")
    func groupMenu() {
        let found = commands(ConnectionTreeMenuSpec.sections(for: .init(clicked: .group(group))))
        #expect(found.contains(.renameGroup(group)))
        #expect(found.last == .deleteGroup(group))
    }

    @Test("Clicking below the last row offers the two ways to add something")
    func backgroundMenu() {
        let found = commands(ConnectionTreeMenuSpec.sections(for: .init(clicked: nil)))
        #expect(found == [.newConnection, .newGroup])
    }

    @Test("Only New Connection carries a shortcut its menu-bar twin actually has")
    func onlyNewConnectionHasAShortcut() {
        #expect(ConnectionTreeMenuCommand.newConnection.shortcutAction == .newConnection)
        for command: ConnectionTreeMenuCommand in [
            .connect(id), .disconnect(id), .edit(id), .duplicate(id), .delete(id),
            .copyConnectionString(id), .newGroup, .renameGroup(group), .deleteGroup(group),
        ] {
            #expect(command.shortcutAction == nil)
        }
    }
}

//
//  DatabaseTreeConnectionRowsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import Testing

/// The saved connections at the top of the tree: which rows stand, and what a click, a double
/// click or Return on one does.
struct DatabaseTreeConnectionRowsTests {
    private static func connectionRow(_ name: String, id: UUID = UUID()) -> ConnectionNavigatorConnectionRow {
        ConnectionNavigatorConnectionRow(
            connection: DatabaseConnection(id: id, name: name),
            groupPath: [],
            isDriverRejected: false,
            status: .notConnected,
            placement: .notOpen
        )
    }

    private static func group(
        _ name: String,
        id: UUID = UUID(),
        isExpanded: Bool = false,
        _ children: [ConnectionNavigatorRow]
    ) -> ConnectionNavigatorRow {
        .group(ConnectionNavigatorGroupRow(
            id: id,
            name: name,
            color: .none,
            iconName: nil,
            connectionCount: children.count,
            isExpanded: isExpanded,
            children: children
        ))
    }

    /// Depth first, the order the outline draws them in when every group is open.
    private static func names(_ rows: [ConnectionNavigatorRow]) -> [String] {
        rows.flatMap { [$0.name] + names($0.children) }
    }

    private static func ref(_ row: ConnectionNavigatorConnectionRow, ownsTree: Bool) -> DatabaseTreeSavedConnectionRef {
        DatabaseTreeSavedConnectionRef(row: row, ownsTree: ownsTree)
    }

    // MARK: - Shape

    @Test("Only the database tree lists the saved connections")
    func onlyTheDatabaseTreeListsConnections() {
        #expect(DatabaseTreeConnectionRows.applies(settingEnabled: true, rootShape: .databaseTree))
        #expect(!DatabaseTreeConnectionRows.applies(settingEnabled: true, rootShape: .flat))
        #expect(!DatabaseTreeConnectionRows.applies(settingEnabled: true, rootShape: .hierarchicalSchema))
        #expect(!DatabaseTreeConnectionRows.applies(settingEnabled: false, rootShape: .databaseTree))
    }

    // MARK: - Rows

    @Test("With no filter the tree lists the library as the connections column builds it")
    func noFilterKeepsTheLibrary() {
        let own = Self.connectionRow("Shop")
        let library = [Self.group("Work", [.connection(own), .connection(Self.connectionRow("Billing"))]),
                       .connection(Self.connectionRow("Local"))]

        let rows = DatabaseTreeConnectionRows.rows(from: library, ownId: own.id, filterText: "")

        #expect(rows == library)
    }

    @Test("A filter keeps the tree's own connection and the connections whose names match, in their groups")
    func filterKeepsOwnAndMatches() throws {
        let own = Self.connectionRow("Shop")
        let groupId = UUID()
        let library = [
            Self.group("Work", id: groupId, [
                .connection(own),
                .connection(Self.connectionRow("Billing")),
                .connection(Self.connectionRow("Reports")),
            ]),
            Self.group("Empty", [.connection(Self.connectionRow("Archive"))]),
            .connection(Self.connectionRow("Local Billing")),
        ]

        let rows = DatabaseTreeConnectionRows.rows(from: library, ownId: own.id, filterText: "  bill ")

        #expect(Self.names(rows) == ["Work", "Shop", "Billing", "Local Billing"])
        guard case .group(let work) = try #require(rows.first) else {
            Issue.record("The group holding a match stays")
            return
        }
        #expect(work.id == groupId)
        #expect(work.isExpanded, "A filter opens every group it leaves")
        #expect(work.connectionCount == 2)
    }

    @Test("A connection the library does not hold is listed first, and only when it is missing")
    func unsavedOwnConnectionIsListedFirst() {
        let unsaved = Self.connectionRow("From a file")
        let saved = Self.connectionRow("Saved")
        let library: [ConnectionNavigatorRow] = [.connection(saved)]

        let withUnsaved = DatabaseTreeConnectionRows.rows(
            from: library, ownId: unsaved.id, unsavedOwnRow: unsaved, filterText: ""
        )
        let withSaved = DatabaseTreeConnectionRows.rows(
            from: library, ownId: saved.id, unsavedOwnRow: saved, filterText: ""
        )

        #expect(Self.names(withUnsaved) == ["From a file", "Saved"])
        #expect(withSaved == library)
    }

    @Test("The groups above a connection are found outermost first")
    func groupsAboveAConnection() {
        let own = Self.connectionRow("Shop")
        let outer = UUID()
        let inner = UUID()
        let library = [
            Self.group("Outer", id: outer, [Self.group("Inner", id: inner, [.connection(own)])]),
            .connection(Self.connectionRow("Local")),
        ]

        #expect(DatabaseTreeConnectionRows.groupIds(above: own.id, in: library) == [outer, inner])
        #expect(DatabaseTreeConnectionRows.groupIds(above: UUID(), in: library) == nil)
        #expect(DatabaseTreeConnectionRows.contains(own.id, in: library))
    }

    // MARK: - Interaction

    @Test("Return on the tree's own connection opens or closes it, on another one switches or opens")
    func activationOfEachKindOfRow() {
        let own = Self.connectionRow("Shop")
        let hosted = Self.connectionRow("Billing")
        let closed = Self.connectionRow("Local")
        let hostedHere: Set<UUID> = [own.id, hosted.id]

        #expect(DatabaseTreeConnectionRows.activation(of: Self.ref(own, ownsTree: true), hostedHere: hostedHere)
            == .toggleDisclosure)
        #expect(DatabaseTreeConnectionRows.activation(of: Self.ref(hosted, ownsTree: false), hostedHere: hostedHere)
            == .switchTo(hosted.id))
        #expect(DatabaseTreeConnectionRows.activation(of: Self.ref(closed, ownsTree: false), hostedHere: hostedHere)
            == .open(closed.id))
    }

    @Test("A click switches only to another connection open in this window")
    func clickSwitchesOnlyBetweenHostedConnections() {
        let own = Self.connectionRow("Shop")
        let hosted = Self.connectionRow("Billing")
        let closed = Self.connectionRow("Local")
        let hostedHere: Set<UUID> = [own.id, hosted.id]
        func target(_ kinds: [DatabaseTreeNode.Kind], click: Bool = true) -> UUID? {
            DatabaseTreeConnectionRows.clickSwitchTarget(selected: kinds, hostedHere: hostedHere, isPointerClick: click)
        }
        let hostedKind = DatabaseTreeNode.Kind.savedConnection(Self.ref(hosted, ownsTree: false))

        #expect(target([hostedKind]) == hosted.id)
        #expect(target([hostedKind], click: false) == nil, "Arrowing down the tree does not hop between workspaces")
        #expect(target([.savedConnection(Self.ref(own, ownsTree: true))]) == nil)
        #expect(target([.savedConnection(Self.ref(closed, ownsTree: false))]) == nil, "A click never dials")
        #expect(target([hostedKind, .recentSection]) == nil, "Extending a selection is not a pick")
    }

    // MARK: - Nodes

    @Test("Only the tree's own connection discloses, and no connection row is a source list group")
    func nodeRules() {
        let own = DatabaseTreeNode(
            id: "own", kind: .savedConnection(Self.ref(Self.connectionRow("Shop"), ownsTree: true))
        )
        let other = DatabaseTreeNode(
            id: "other", kind: .savedConnection(Self.ref(Self.connectionRow("Local"), ownsTree: false))
        )
        let group = DatabaseTreeNode(id: "group", kind: Self.group("Work", [.connection(Self.connectionRow("A"))]).treeKind)
        let emptyGroup = DatabaseTreeNode(id: "empty", kind: Self.group("Empty", []).treeKind)

        #expect(own.isExpandable)
        #expect(!other.isExpandable)
        #expect(group.isExpandable)
        #expect(!emptyGroup.isExpandable)
        for node in [own, other, group] {
            #expect(!node.isGroupRow)
            #expect(!node.isContainer)
            #expect(DatabaseTreeSelection.isSelectable(node.kind))
            #expect(DatabaseTreeSelection.tableRef(of: node) == nil)
        }
        #expect(!own.opensWithAncestor(showsTableDetails: false), "Option-opening a group does not open every database")
        #expect(DatabaseTreeTypeSelect.matchString(for: own.kind) == "Shop")
        #expect(DatabaseTreeTypeSelect.matchString(for: group.kind) == "Work")
    }

    @Test("A double click opens another connection and discloses the tree's own")
    func doubleClickIntent() {
        let otherRef = Self.ref(Self.connectionRow("Local"), ownsTree: false)
        let own = DatabaseTreeNode(
            id: "own", kind: .savedConnection(Self.ref(Self.connectionRow("Shop"), ownsTree: true))
        )

        #expect(DatabaseTreeDoubleClickResolver.resolve(node: DatabaseTreeNode(id: "other", kind: .savedConnection(otherRef)))
            == .activateConnection(otherRef))
        #expect(DatabaseTreeDoubleClickResolver.resolve(node: own) == .toggleDisclosure)
    }
}

private extension ConnectionNavigatorRow {
    var treeKind: DatabaseTreeNode.Kind {
        switch self {
        case .group(let group): return .connectionGroup(group)
        case .connection(let connection): return .savedConnection(DatabaseTreeSavedConnectionRef(row: connection, ownsTree: false))
        }
    }
}

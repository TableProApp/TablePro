//
//  ConnectionNavigatorRowsBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import Testing

struct ConnectionNavigatorRowsBuilderTests {
    private static func connection(
        _ name: String,
        host: String = "localhost",
        in groupId: UUID? = nil,
        sortOrder: Int = 0
    ) -> DatabaseConnection {
        DatabaseConnection(name: name, host: host, groupId: groupId, sortOrder: sortOrder)
    }

    private static func group(_ name: String, parent: UUID? = nil, sortOrder: Int = 0) -> ConnectionGroup {
        ConnectionGroup(name: name, parentId: parent, sortOrder: sortOrder)
    }

    /// Depth first, the order the outline draws them in when every group is open.
    private static func ids(_ rows: [ConnectionNavigatorRow]) -> [ConnectionNavigatorRowID] {
        rows.flatMap { [$0.id] + ids($0.children) }
    }

    private static func groupRow(_ id: UUID, in rows: [ConnectionNavigatorRow]) -> ConnectionNavigatorGroupRow? {
        for row in rows {
            if case .group(let group) = row {
                if group.id == id { return group }
                if let nested = groupRow(id, in: group.children) { return nested }
            }
        }
        return nil
    }

    private static func connectionRow(_ id: UUID, in rows: [ConnectionNavigatorRow]) -> ConnectionNavigatorConnectionRow? {
        for row in rows {
            switch row {
            case .connection(let connection) where connection.id == id:
                return connection
            case .connection:
                continue
            case .group(let group):
                if let nested = connectionRow(id, in: group.children) { return nested }
            }
        }
        return nil
    }

    @Test("Groups nest under their parent and keep the user's order")
    func groupsNestByParentAndSortOrder() throws {
        let groupA = Self.group("A", sortOrder: 1)
        let groupB = Self.group("B", sortOrder: 0)
        let groupC = Self.group("C", parent: groupA.id)
        let inA = Self.connection("a1", in: groupA.id)
        let inC = Self.connection("c1", in: groupC.id)
        let loose = Self.connection("u1")

        let rows = ConnectionNavigatorRowsBuilder.build(ConnectionNavigatorRowsInput(
            connections: [loose, inC, inA],
            groups: [groupA, groupB, groupC]
        ))

        #expect(Self.ids(rows) == [
            .group(groupB.id), .group(groupA.id), .group(groupC.id),
            .connection(inC.id), .connection(inA.id), .connection(loose.id),
        ])
        #expect(try #require(Self.groupRow(groupA.id, in: rows)).connectionCount == 2)
    }

    @Test("Name sort orders groups and connections by name")
    func nameSortOrdersByName() {
        let beta = Self.group("Beta", sortOrder: 0)
        let alpha = Self.group("Alpha", sortOrder: 1)
        let second = Self.connection("b", sortOrder: 0)
        let first = Self.connection("a", sortOrder: 1)

        let rows = ConnectionNavigatorRowsBuilder.build(ConnectionNavigatorRowsInput(
            connections: [second, first],
            groups: [beta, alpha],
            sortMode: .name
        ))

        #expect(Self.ids(rows) == [.group(alpha.id), .group(beta.id), .connection(first.id), .connection(second.id)])
    }

    @Test("The filter matches names, hosts and group names, and opens the groups holding a match")
    func filterMatchesNameHostAndGroupAndExpands() throws {
        let production = Self.group("Production")
        let analytics = Self.group("Analytics")
        let byHost = Self.connection("orders", host: "prod-db.internal", in: production.id)
        let other = Self.connection("billing", in: production.id)
        let reports = Self.connection("reports", in: analytics.id)
        let warehouse = Self.connection("warehouse", in: analytics.id)
        let input = ConnectionNavigatorRowsInput(
            connections: [byHost, other, reports, warehouse],
            groups: [production, analytics]
        )

        var hostFilter = input
        hostFilter.filterText = "prod-db"
        let hostRows = ConnectionNavigatorRowsBuilder.build(hostFilter)
        let matchedGroup = try #require(Self.groupRow(production.id, in: hostRows))
        #expect(matchedGroup.isExpanded)
        #expect(Self.ids(matchedGroup.children) == [.connection(byHost.id)])
        #expect(Self.groupRow(analytics.id, in: hostRows) == nil)

        var groupFilter = input
        groupFilter.filterText = "analytics"
        let groupRows = ConnectionNavigatorRowsBuilder.build(groupFilter)
        let namedGroup = try #require(Self.groupRow(analytics.id, in: groupRows))
        #expect(Set(Self.ids(namedGroup.children)) == [.connection(reports.id), .connection(warehouse.id)])

        var nameFilter = input
        nameFilter.filterText = "billing"
        #expect(Self.connectionRow(other.id, in: ConnectionNavigatorRowsBuilder.build(nameFilter)) != nil)
    }

    @Test("A collapsed group is marked collapsed and still carries its children")
    func collapsedGroupIsMarkedCollapsed() throws {
        let open = Self.group("Open", sortOrder: 0)
        let closed = Self.group("Closed", sortOrder: 1)
        let inClosed = Self.connection("inside", in: closed.id)

        let rows = ConnectionNavigatorRowsBuilder.build(ConnectionNavigatorRowsInput(
            connections: [inClosed],
            groups: [open, closed],
            expandedGroupIds: [open.id]
        ))

        #expect(try #require(Self.groupRow(open.id, in: rows)).isExpanded)
        let collapsed = try #require(Self.groupRow(closed.id, in: rows))
        #expect(!collapsed.isExpanded)
        #expect(Self.ids(collapsed.children) == [.connection(inClosed.id)])
    }

    @Test("An empty library, and a filter that matches nothing, build no rows")
    func emptyLibraryAndNoMatchBuildNothing() {
        #expect(ConnectionNavigatorRowsBuilder.build(ConnectionNavigatorRowsInput(connections: [], groups: [])).isEmpty)

        var input = ConnectionNavigatorRowsInput(connections: [Self.connection("orders")], groups: [Self.group("G")])
        input.filterText = "zzz"
        #expect(ConnectionNavigatorRowsBuilder.build(input).isEmpty)
    }

    @Test("Status, placement and a rejected driver come from the input, with quiet defaults")
    func statusPlacementAndDriverComeFromInput() throws {
        let marked = Self.connection("marked")
        let plain = Self.connection("plain")

        let rows = ConnectionNavigatorRowsBuilder.build(ConnectionNavigatorRowsInput(
            connections: [marked, plain],
            groups: [],
            statuses: [marked.id: .connecting],
            placements: [marked.id: .openElsewhere],
            driverRejectedIds: [marked.id]
        ))

        let markedRow = try #require(Self.connectionRow(marked.id, in: rows))
        #expect(markedRow.status == .connecting)
        #expect(markedRow.placement == .openElsewhere)
        #expect(markedRow.isDriverRejected)
        let plainRow = try #require(Self.connectionRow(plain.id, in: rows))
        #expect(plainRow.status == .notConnected)
        #expect(plainRow.placement == .notOpen)
        #expect(!plainRow.isDriverRejected)
    }

    @Test("Applying new statuses changes only status and placement")
    func applyingReplacesOnlyStatusAndPlacement() throws {
        let group = Self.group("G")
        let nested = Self.connection("nested", in: group.id)
        let rows = ConnectionNavigatorRowsBuilder.build(ConnectionNavigatorRowsInput(
            connections: [nested],
            groups: [group],
            expandedGroupIds: [group.id]
        ))

        let updated = ConnectionNavigatorRowsBuilder.applying(
            statuses: [nested.id: .connected],
            placements: [nested.id: .shownHere],
            to: rows
        )

        #expect(Self.ids(updated) == Self.ids(rows))
        #expect(try #require(Self.groupRow(group.id, in: updated)).isExpanded)
        let row = try #require(Self.connectionRow(nested.id, in: updated))
        #expect(row.status == .connected)
        #expect(row.placement == .shownHere)
    }

    @Test("A connection's placement follows the window that shows it")
    func placementOrder() {
        let shown = UUID()
        let hosted = UUID()
        let elsewhere = UUID()
        let closed = UUID()
        let hostedHere: Set<UUID> = [shown, hosted]
        let hostedAnywhere: Set<UUID> = [shown, hosted, elsewhere]

        func placement(_ id: UUID) -> ConnectionNavigatorPlacement {
            ConnectionNavigatorRowsBuilder.placement(
                of: id, shown: shown, hostedHere: hostedHere, hostedAnywhere: hostedAnywhere
            )
        }

        #expect(placement(shown) == .shownHere)
        #expect(placement(hosted) == .openHere)
        #expect(placement(elsewhere) == .openElsewhere)
        #expect(placement(closed) == .notOpen)
    }

    /// Another Mac can delete a parent group while this one still holds its child.
    @Test("A group whose parent is gone shows at the top level with its connections")
    func orphanGroupShowsAtTopLevel() throws {
        let orphan = Self.group("Orphan", parent: UUID())
        let inside = Self.connection("inside", in: orphan.id)

        let rows = ConnectionNavigatorRowsBuilder.build(ConnectionNavigatorRowsInput(
            connections: [inside],
            groups: [orphan]
        ))

        #expect(rows.map { $0.id } == [.group(orphan.id)])
        #expect(Self.ids(try #require(Self.groupRow(orphan.id, in: rows)).children) == [.connection(inside.id)])
    }

    @Test("A filter of only spaces is no filter")
    func blankFilterIsNoFilter() throws {
        let group = Self.group("G")
        let inside = Self.connection("inside", in: group.id)
        var input = ConnectionNavigatorRowsInput(connections: [inside], groups: [group])
        input.filterText = "   "

        let rows = ConnectionNavigatorRowsBuilder.build(input)

        let row = try #require(Self.groupRow(group.id, in: rows))
        #expect(!row.isExpanded)
        #expect(Self.ids(row.children) == [.connection(inside.id)])
    }
}

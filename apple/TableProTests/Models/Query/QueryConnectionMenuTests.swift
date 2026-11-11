//
//  QueryConnectionMenuTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import Testing

@MainActor
struct QueryConnectionMenuTests {
    @Test("Saved connections keep the sidebar's groups and order, and an empty group is left out")
    func groupsLikeTheSidebar() {
        let production = ConnectionGroup(name: "Production", sortOrder: 0)
        let empty = ConnectionGroup(name: "Archive", sortOrder: 1)
        let shop = DatabaseConnection(name: "Shop", color: .red, groupId: production.id, sortOrder: 0)
        let billing = DatabaseConnection(name: "Billing", groupId: production.id, sortOrder: 1)
        let local = DatabaseConnection(name: "Local", color: .green)

        let rows = ConnectionNavigatorRowsBuilder.build(ConnectionNavigatorRowsInput(
            connections: [local, billing, shop],
            groups: [empty, production]
        ))

        #expect(QueryConnectionMenu.items(from: rows) == [
            .group(id: production.id, name: "Production", children: [
                .connection(id: shop.id, name: "Shop", color: .red),
                .connection(id: billing.id, name: "Billing", color: .none),
            ]),
            .connection(id: local.id, name: "Local", color: .green),
        ])
    }

    @Test("Choosing another connection moves the tab there through the move it was handed")
    func choosingMovesTheTab() {
        let current = UUID()
        let target = UUID()
        var moves: [UUID] = []
        let model = QueryConnectionPickerModel(
            connectionId: current,
            name: "Shop",
            color: .none,
            canMove: true,
            move: { moves.append($0) }
        )

        model.choose(target)
        model.choose(current)

        #expect(moves == [target], "The connection the tab is on is no move")
    }

    @Test("A tab that cannot move stays put, and the picker says why")
    func busyTabStaysPut() {
        var moves: [UUID] = []
        let model = QueryConnectionPickerModel(
            connectionId: UUID(),
            name: "Shop",
            color: .none,
            canMove: false,
            move: { moves.append($0) }
        )

        model.choose(UUID())

        #expect(moves.isEmpty)
        #expect(model.hint.contains("cannot move"))
    }

    /// The menu runs the same policy as Database > Move Tab to Connection: a running query keeps its
    /// tab on the connection it was sent to.
    @Test("A tab whose query is running cannot move")
    func runningTabCannotMove() {
        #expect(EditorTabConnectionMovePolicy.canMove(tabType: .query, isBusy: false, hasPendingGridEdits: false))
        #expect(!EditorTabConnectionMovePolicy.canMove(tabType: .query, isBusy: true, hasPendingGridEdits: false))
    }
}

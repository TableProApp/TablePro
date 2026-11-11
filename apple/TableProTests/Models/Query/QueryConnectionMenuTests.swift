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

    /// What a pick asked and what it moved, so a case reads both.
    private final class PickLog {
        var asked: [UUID] = []
        var moves: [UUID] = []
    }

    private static func picker(
        connectionId: UUID = UUID(),
        canMove: Bool = true,
        answer: Bool,
        log: PickLog
    ) -> QueryConnectionPickerModel {
        QueryConnectionPickerModel(
            connectionId: connectionId,
            name: "Shop",
            color: .none,
            canMove: canMove,
            confirm: { target in
                log.asked.append(target)
                return answer
            },
            move: { log.moves.append($0) }
        )
    }

    @Test("Choosing another connection asks first, and a yes moves the tab through the move it was handed")
    func confirmedPickMovesTheTab() async {
        let current = UUID()
        let target = UUID()
        let log = PickLog()
        let model = Self.picker(connectionId: current, answer: true, log: log)

        await model.choose(target)
        await model.choose(current)

        #expect(log.asked == [target], "The connection the tab is on is no move, so nothing is asked")
        #expect(log.moves == [target])
    }

    @Test("Cancelling the question leaves the tab where it is")
    func cancelledPickMovesNothing() async {
        let target = UUID()
        let log = PickLog()
        let model = Self.picker(answer: false, log: log)

        await model.choose(target)

        #expect(log.asked == [target])
        #expect(log.moves.isEmpty)
    }

    @Test("A tab that cannot move stays put without a question, and the picker says why")
    func busyTabStaysPut() async {
        let log = PickLog()
        let model = Self.picker(canMove: false, answer: true, log: log)

        await model.choose(UUID())

        #expect(log.asked.isEmpty)
        #expect(log.moves.isEmpty)
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

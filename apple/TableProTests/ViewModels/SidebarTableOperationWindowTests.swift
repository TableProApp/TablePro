import Foundation
import SwiftUI
import Testing
@testable import TablePro

@MainActor
struct SidebarTableOperationWindowTests {
    private final class ConnectionQueues {
        var truncates: Set<DatabaseTreeTableRef> = []
        var deletes: Set<DatabaseTreeTableRef> = []
        var options: [DatabaseTreeTableRef: TableOperationOptions] = [:]
    }

    private let queues = ConnectionQueues()

    private func makeSharedViewModel() -> SidebarViewModel {
        let queues = queues
        return SidebarViewModel(
            pendingTruncates: Binding(get: { queues.truncates }, set: { queues.truncates = $0 }),
            pendingDeletes: Binding(get: { queues.deletes }, set: { queues.deletes = $0 }),
            tableOperationOptions: Binding(get: { queues.options }, set: { queues.options = $0 }),
            databaseType: .mysql,
            connectionId: UUID()
        )
    }

    private func makeRef(_ name: String) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(database: "shop", schema: nil, table: TestFixtures.makeTableInfo(name: name))
    }

    @Test("A truncate asks only the window it came from, and its confirm writes that window's tables")
    func truncateBelongsToTheAskingWindow() throws {
        let viewModel = makeSharedViewModel()
        let windowA = WindowSidebarState()
        let windowB = WindowSidebarState()
        let users = makeRef("users")
        let orders = makeRef("orders")
        windowA.selectTables([users])
        windowB.selectTables([orders])

        viewModel.batchToggleTruncate(refs: Array(windowA.selectedTables), from: windowA)

        let requestA = try #require(windowA.pendingTableOperation)
        #expect(requestA.operation == .truncate)
        #expect(requestA.tables == [users])
        #expect(windowB.pendingTableOperation == nil)

        viewModel.batchToggleDelete(refs: Array(windowB.selectedTables), from: windowB)
        let requestB = try #require(windowB.pendingTableOperation)
        #expect(windowA.pendingTableOperation == requestA)

        let options = TableOperationOptions(ignoreForeignKeys: true)
        viewModel.confirmOperation(requestA, options: options)
        windowA.resolveTableOperation(requestA)

        #expect(queues.truncates == [users])
        #expect(queues.deletes.isEmpty)
        #expect(queues.options == [users: options])
        #expect(windowA.pendingTableOperation == nil)
        #expect(windowB.pendingTableOperation == requestB)
    }

    @Test("Answering an earlier prompt acts on its own tables, not on a request posted after it")
    func confirmActsOnTheRequestItWasShownFor() throws {
        let viewModel = makeSharedViewModel()
        let window = WindowSidebarState()
        let users = makeRef("users")
        let orders = makeRef("orders")

        viewModel.batchToggleTruncate(refs: [users], from: window)
        let first = try #require(window.pendingTableOperation)
        viewModel.batchToggleDelete(refs: [orders], from: window)
        let second = try #require(window.pendingTableOperation)

        let options = TableOperationOptions(cascade: true)
        viewModel.confirmOperation(first, options: options)
        window.resolveTableOperation(first)

        #expect(queues.truncates == [users])
        #expect(queues.deletes.isEmpty)
        #expect(queues.options == [users: options])
        #expect(window.pendingTableOperation == second)

        window.resolveTableOperation(second)

        #expect(window.pendingTableOperation == nil)
        #expect(queues.deletes.isEmpty)
    }
}

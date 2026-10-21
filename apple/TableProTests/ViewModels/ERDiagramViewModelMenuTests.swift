// A context menu leaves out what the engine cannot do, rather than dimming it, and sets its
// destructive items last.

import AppKit
@testable import TablePro
import Testing

@MainActor
struct ERDiagramViewModelMenuTests {
    private func viewModel(_ type: DatabaseType) -> ERDiagramViewModel {
        let connection = TestFixtures.makeConnection(database: "shop", type: type)
        return ERDiagramViewModel(
            connectionId: connection.id,
            databaseName: "shop",
            schemaKey: "shop.public",
            connection: connection
        )
    }

    private func titles(_ sections: [[ERDiagramMenuEntry]]) -> [String] {
        sections.flatMap { $0 }.map { $0.title }
    }

    @Test("A table's menu opens it, shows its structure and copies its name")
    func tableMenu() {
        let sections = viewModel(.postgresql).menuSections(for: .table("orders"))
        let commands = sections.flatMap { $0 }.map { $0.command }

        #expect(commands.contains(.openTable("orders")))
        #expect(commands.contains(.showStructure("orders")))
        #expect(commands.contains(.copyName("orders")))
        #expect(commands.contains(.addColumn(table: "orders")))
    }

    @Test("A column's menu offers its key and column edits, and puts Delete Column last")
    func columnMenu() throws {
        let sections = viewModel(.postgresql).menuSections(for: .column(table: "orders", column: "customer_id"))
        let commands = sections.flatMap { $0 }.map { $0.command }

        #expect(commands.contains(.addForeignKey(table: "orders", column: "customer_id")))
        #expect(commands.contains(.renameColumn(table: "orders", column: "customer_id")))
        let last = try #require(sections.last { !$0.isEmpty }?.last)
        #expect(last.command == .dropColumn(table: "orders", column: "customer_id"))
    }

    @Test("An engine that cannot add or remove foreign keys gets no key items")
    func keyItemsFollowTheEngine() {
        let sections = viewModel(.clickhouse).menuSections(for: .column(table: "orders", column: "customer_id"))
        let commands = sections.flatMap { $0 }.map { $0.command }

        #expect(!commands.contains(.addForeignKey(table: "orders", column: "customer_id")))
    }

    @Test("A view on the canvas is drawn but offers no structure edits, and no key can point at it")
    func viewNodesAreReadOnly() async throws {
        let fixture = ERDiagramLoadFixture(tableCount: 2, columnsPerTable: 2)
        defer { fixture.tearDown() }
        fixture.driver.list([
            TestFixtures.makeTableInfo(name: "table_0", type: .table),
            TestFixtures.makeTableInfo(name: "table_1", type: .view)
        ])
        let viewModel = fixture.viewModel
        await viewModel.loadDiagram()

        let viewCommands = viewModel.menuSections(for: .column(table: "table_1", column: "column_1"))
            .flatMap { $0 }.map { $0.command }
        let tableCommands = viewModel.menuSections(for: .column(table: "table_0", column: "column_1"))
            .flatMap { $0 }.map { $0.command }

        #expect(viewCommands.contains(.openTable("table_1")))
        #expect(!viewCommands.contains(.dropColumn(table: "table_1", column: "column_1")))
        #expect(!viewCommands.contains(.addColumn(table: "table_1")))
        #expect(tableCommands.contains(.dropColumn(table: "table_0", column: "column_1")))
        #expect(viewModel.referenceableTables == ["table_0"])
    }

    @Test("The canvas offers Refresh, and New Table only where a table can be created")
    func canvasMenu() {
        let sections = viewModel(.postgresql).menuSections(for: .canvas(CGPoint(x: 10, y: 20)))

        #expect(titles(sections) == ["Refresh"])
    }
}

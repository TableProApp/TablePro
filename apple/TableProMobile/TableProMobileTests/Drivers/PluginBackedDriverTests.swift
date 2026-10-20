import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

struct PluginBackedDriverTests {
    private func makeDriver(_ plugin: StubPluginDriver, identity: RowIdentity = .everyColumn) -> PluginBackedDriver {
        PluginBackedDriver(
            plugin: plugin,
            dialedHosts: [],
            rowIdentity: identity,
            readsOnly: { $0.uppercased().hasPrefix("SELECT") }
        )
    }

    private func drain(_ stream: AsyncThrowingStream<StreamElement, Error>) async throws -> [StreamElement] {
        var elements: [StreamElement] = []
        for try await element in stream {
            elements.append(element)
        }
        return elements
    }

    private func result(rows: [[PluginCellValue]]) -> PluginQueryResult {
        PluginQueryResult(
            columns: ["id", "name"],
            columnTypeNames: ["UInt64", "String"],
            rows: rows,
            rowsAffected: 0,
            timing: PluginQueryTiming(total: 0)
        )
    }

    @Test("A read is bounded at its source by the page's row cap")
    func readIsBounded() async throws {
        let plugin = StubPluginDriver()
        plugin.scriptedResult = result(rows: [["1", "a"], ["2", "b"]])
        let driver = makeDriver(plugin)

        let elements = try await drain(driver.executeStreaming(query: "SELECT * FROM t", options: StreamOptions(maxRows: 50)))

        #expect(plugin.boundedQueries.map { $0.rowCap } == [50])
        #expect(plugin.plainQueries.isEmpty)
        #expect(elements.filter { if case .row = $0 { true } else { false } }.count == 2)
    }

    @Test("A write runs whole, never through the bounded fetch that abandons the statement")
    func writeRunsWhole() async throws {
        let plugin = StubPluginDriver()
        let driver = makeDriver(plugin)

        _ = try await drain(driver.executeStreaming(query: "INSERT INTO t VALUES (1)", options: StreamOptions(maxRows: 50)))

        #expect(plugin.boundedQueries.isEmpty)
        #expect(plugin.plainQueries == ["INSERT INTO t VALUES (1)"])
    }

    @Test("Rows past the cap end the stream as truncated")
    func capTruncates() async throws {
        let plugin = StubPluginDriver()
        plugin.answersBoundedReads = false
        plugin.scriptedResult = result(rows: [["1", "a"], ["2", "b"], ["3", "c"]])
        let driver = makeDriver(plugin)

        let elements = try await drain(driver.executeStreaming(query: "SELECT 1", options: StreamOptions(maxRows: 2)))

        #expect(elements.filter { if case .row = $0 { true } else { false } }.count == 2)
        let truncated = elements.contains { element in
            if case .truncated = element { return true }
            return false
        }
        #expect(truncated)
    }

    @Test("A cut-off cell carries a full-value reference built from the key columns")
    func lazyReferenceFromKeys() async throws {
        let plugin = StubPluginDriver()
        let long = String(repeating: "x", count: 5_000)
        plugin.scriptedResult = result(rows: [["7", .text(long)]])
        let driver = makeDriver(plugin, identity: .keyColumns)
        let options = StreamOptions(maxRows: 10, lazyContext: LazyContext(table: "t", primaryKeyColumns: ["id"]))

        let elements = try await drain(driver.executeStreaming(query: "SELECT * FROM t", options: options))

        let row = try #require(elements.compactMap { element -> Row? in
            if case .row(let row) = element { return row }
            return nil
        }.first)
        guard case .truncatedText(_, _, let ref) = row.cells[1] else {
            Issue.record("the long cell should be cut off")
            return
        }
        #expect(ref?.primaryKey == [PrimaryKeyComponent(column: "id", value: "7")])
    }

    @Test("An engine without transactions reports nothing pending")
    func noTransactionsMeansIdle() async {
        let plugin = StubPluginDriver()
        let driver = makeDriver(plugin)

        #expect(await driver.sessionTransactionState() == .idle)
        #expect(driver.supportsTransactions == false)
    }

    @Test("String literals are escaped by the plugin, not the ANSI default")
    func escapingComesFromThePlugin() {
        let driver = makeDriver(StubPluginDriver())

        #expect(driver.escapeStringLiteral("it's") == "escaped:it's")
    }

    @Test("A row edit hands the plugin the row as it was read and the changed cell, then binds its parameters")
    func updateHandsThePluginTheWholeRow() async throws {
        let plugin = StubPluginDriver()
        let driver = makeDriver(plugin)

        let writes = try driver.updateWrites(
            table: "events",
            schema: nil,
            columns: ["id", "name", "note"],
            originalRow: ["1", "signup", nil],
            changes: [(column: "name", value: "purchase")]
        )
        _ = try await driver.run(writes)

        let change = try #require(plugin.generatedChanges.first)
        #expect(change.type == .update)
        #expect(change.originalRow == ["1", "signup", .null])
        #expect(change.cellChanges.map { $0.columnIndex } == [1])
        #expect(change.cellChanges.map { $0.newValue } == ["purchase"])
        #expect(plugin.generatedColumns == ["id", "name", "note"])
        #expect(plugin.parameterizedQueries.map { $0.query } == ["WRITE update events"])
    }

    @Test("A new row marks every column it leaves out as the server default")
    func insertLeavesOmittedColumnsToTheServer() throws {
        let plugin = StubPluginDriver()
        let driver = makeDriver(plugin)

        _ = try driver.insertWrites(
            table: "events", schema: nil, columns: ["id", "name", "note"], values: [(column: "name", value: "x")]
        )

        #expect(plugin.generatedInserts[0] == [
            .text(PluginBackedDriver.defaultSentinel), "x", .text(PluginBackedDriver.defaultSentinel)
        ])
    }

    @Test("Catalog columns keep their order and key flags")
    func columnsConvert() async throws {
        let plugin = StubPluginDriver()
        plugin.scriptedColumns = [
            PluginColumnInfo(name: "id", dataType: "UInt64", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: "name", dataType: "String")
        ]
        let driver = makeDriver(plugin)

        let columns = try await driver.fetchColumns(table: "events", schema: nil)

        #expect(columns.map(\.name) == ["id", "name"])
        #expect(columns.map(\.ordinalPosition) == [0, 1])
        #expect(columns.map(\.isPrimaryKey) == [true, false])
    }
}

import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

struct PluginBackedDriverTests {
    private func makeDriver(_ plugin: StubPluginDriver) -> PluginBackedDriver {
        PluginBackedDriver(plugin: plugin, dialedHosts: [], readsOnly: { $0.uppercased().hasPrefix("SELECT") })
    }

    private func makeWriter(_ plugin: StubPluginDriver) -> PluginRowWritingDriver {
        PluginRowWritingDriver(
            plugin: plugin,
            dialedHosts: [],
            rowIdentity: .everyColumn,
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

    private func rows(of elements: [StreamElement]) -> [Row] {
        elements.compactMap { element -> Row? in
            if case .row(let row) = element { return row }
            return nil
        }
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
        let driver = makeDriver(plugin)
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

    @Test("A row and its cut-off cell carry the locator the plugin read the row with")
    func rowCarriesThePluginLocator() async throws {
        let plugin = StubPluginDriver()
        plugin.scriptedResult = result(rows: [["7", .text(String(repeating: "x", count: 5_000))], ["8", "b"]])
        plugin.scriptedResult.rowLocators = [#"{"$oid":"7"}"#, nil]
        let driver = makeDriver(plugin)
        let options = StreamOptions(maxRows: 10, lazyContext: LazyContext(table: "t", primaryKeyColumns: ["id"]))

        let read = try await rows(of: drain(driver.executeStreaming(query: "SELECT * FROM t", options: options)))

        #expect(read.map { $0.locator } == [#"{"$oid":"7"}"#, nil])
        let first = try #require(read.first)
        guard case .truncatedText(_, _, let ref) = first.cells[1] else {
            Issue.record("the long cell should be cut off")
            return
        }
        #expect(ref?.locator == #"{"$oid":"7"}"#)
    }

    @Test("Locators that do not pair one to one with the rows are dropped")
    func unpairedLocatorsAreDropped() async throws {
        let plugin = StubPluginDriver()
        plugin.scriptedResult = result(rows: [["7", .text(String(repeating: "x", count: 5_000))], ["8", "b"]])
        plugin.scriptedResult.rowLocators = [#"{"$oid":"7"}"#]
        let driver = makeDriver(plugin)
        let options = StreamOptions(maxRows: 10, lazyContext: LazyContext(table: "t", primaryKeyColumns: ["id"]))

        let read = try await rows(of: drain(driver.executeStreaming(query: "SELECT * FROM t", options: options)))

        #expect(read.map { $0.locator } == [nil, nil])
        let first = try #require(read.first)
        guard case .truncatedText(_, _, let ref) = first.cells[1] else {
            Issue.record("the long cell should be cut off")
            return
        }
        #expect(ref != nil)
        #expect(ref?.locator == nil)
    }

    @Test("Bytes stay a binary cell, so a row holding them is never matched by its hex text")
    func bytesStayBinary() async throws {
        let plugin = StubPluginDriver()
        plugin.scriptedResult = result(rows: [["1", .bytes(Data([0xFF, 0x00]))]])
        let driver = makeDriver(plugin)

        let elements = try await drain(driver.executeStreaming(query: "SELECT * FROM t", options: StreamOptions(maxRows: 10)))

        let row = try #require(elements.compactMap { element -> Row? in
            if case .row(let row) = element { return row }
            return nil
        }.first)
        guard case .binary(let count, _) = row.cells[1] else {
            Issue.record("bytes should arrive as a binary cell")
            return
        }
        #expect(count == 2)
        let columns = [ColumnInfo(name: "id", typeName: "UInt64"), ColumnInfo(name: "name", typeName: "String")]
        #expect(RowLocator.locate(cells: row.cells, columns: columns, columnDetails: columns, identity: .everyColumn) == nil)
    }

    // The Mac writes such a plugin's rows with its own SQL; on iOS that is SQLBuilder, reached only by a non-writer.
    @Test("A plugin that generates no row writes of its own leaves its driver out of the row writers")
    func plainPluginIsNotARowWriter() {
        let plain: any DatabaseDriver = makeDriver(StubPluginDriver())
        let writer: any DatabaseDriver = makeWriter(StubPluginDriver())

        #expect(!(plain is any DriverRowWriting))
        #expect(writer is any DriverRowWriting)
        #expect(RowLocator.identity(of: plain) == .keyColumns)
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
        let driver = makeWriter(plugin)

        let writes = try driver.updateWrites(
            table: "events",
            schema: nil,
            columns: ["id", "name", "note"],
            originalRow: ["1", "signup", nil],
            documentLocator: nil,
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
        let driver = makeWriter(plugin)

        _ = try driver.insertWrites(
            table: "events", schema: nil, columns: ["id", "name", "note"], values: [(column: "name", value: "x")]
        )

        #expect(plugin.generatedInserts[0] == [
            .text(PluginRowWritingDriver.defaultSentinel), "x", .text(PluginRowWritingDriver.defaultSentinel)
        ])
    }

    @Test("A plugin that reads the default mark gets every left-out column marked")
    func insertMarksOmittedColumnsForAMarkingPlugin() throws {
        let plugin = StubPluginDriver()
        plugin.declaredCapabilities = .columnDefaultMarks
        let driver = makeWriter(plugin)

        _ = try driver.insertWrites(
            table: "events", schema: nil, columns: ["id", "name", "note"], values: [(column: "name", value: "x")]
        )

        #expect(plugin.generatedChanges.first?.defaultColumns == [0, 2])
    }

    @Test("A plugin that reads the default mark stores the marker's text as a value")
    func markingPluginStoresTheMarkerText() throws {
        let plugin = StubPluginDriver()
        plugin.declaredCapabilities = .columnDefaultMarks
        let driver = makeWriter(plugin)

        _ = try driver.insertWrites(
            table: "events", schema: nil, columns: ["id", "note"],
            values: [(column: "id", value: "1"), (column: "note", value: PluginRowWritingDriver.defaultSentinel)]
        )

        #expect(plugin.generatedInserts[0] == ["1", .text(PluginRowWritingDriver.defaultSentinel)])
        #expect(plugin.generatedChanges.first?.defaultColumns == nil)
    }

    @Test("A value spelled as the default marker is refused, never stored as the default")
    func insertRefusesTheDefaultMarker() {
        let plugin = StubPluginDriver()
        let driver = makeWriter(plugin)

        #expect(throws: DatabaseError.self) {
            try driver.insertWrites(
                table: "events", schema: nil, columns: ["id", "note"],
                values: [(column: "id", value: "1"), (column: "note", value: PluginRowWritingDriver.defaultSentinel)]
            )
        }
        #expect(plugin.generatedInserts.isEmpty)
    }

    @Test("The connection's saved query timeout reaches the plugin, and none is sent when it has none", arguments: [
        (Int?.some(0), [0]), (Int?.some(30), [30]), (Int?.none, [Int]())
    ])
    func savedQueryTimeoutIsApplied(saved: Int?, applied: [Int]) async throws {
        let plugin = StubPluginDriver()
        let driver = PluginBackedDriver(plugin: plugin, dialedHosts: [], queryTimeoutSeconds: saved, readsOnly: { _ in true })

        try await driver.connect()

        #expect(plugin.appliedQueryTimeouts == applied)
    }

    // The plugin's own cancel stops whichever request it sent last, which can be another window's.
    @Test("Stop leaves the plugin's driver-wide cancel alone")
    func stopDoesNotCancelTheLatestRequest() async throws {
        let plugin = StubPluginDriver()

        try await makeDriver(plugin).cancelCurrentQuery()

        #expect(plugin.cancelQueryCalls == 0)
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

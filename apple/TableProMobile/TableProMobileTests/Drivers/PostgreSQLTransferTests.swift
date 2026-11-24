import Foundation
import os
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProPostgreSQLCore
import Testing
@testable import TableProMobile

@Suite(.timeLimit(.minutes(1)))
struct PostgreSQLTransferTests {
    private static let report = "SELECT flag, data, note FROM orders"
    private static let typedColumns = [
        FakePostgreSQLServer.Column(name: "flag", oid: 16),
        FakePostgreSQLServer.Column(name: "data", oid: 17),
        FakePostgreSQLServer.Column(name: "note", oid: 25),
    ]
    private static let typedRows: [[String?]] = [["t", "\\x01ff", nil], ["f", "\\x", "x"]]

    @Test("An export reads booleans and bytea as the Mac does, with the column types in the header")
    func exportRowsDecodeAsTheMac() async throws {
        let server = try FakePostgreSQLServer(replies: [Self.report: .typed(Self.typedColumns, rows: Self.typedRows)])
        let run = try await Self.run(on: server) { driver in
            try await Self.collect(driver.exportRows(query: Self.report, readOnly: false))
        }

        #expect(run.read.columns == ["flag", "data", "note"])
        #expect(run.read.typeNames == ["boolean", "bytea", "text"])
        #expect(run.read.rows == [
            [.text("true"), .bytes(Data([0x01, 0xFF])), .null],
            [.text("false"), .bytes(Data()), .text("x")],
        ])
    }

    @Test("An export reads every row, past the grid's cap, in batches")
    func exportRowsHaveNoCap() async throws {
        let server = try FakePostgreSQLServer(replies: ["SELECT n FROM big": .rows(2_500)])
        let run = try await Self.run(on: server) { driver in
            try await Self.collect(driver.exportRows(query: "SELECT n FROM big", readOnly: false))
        }

        #expect(run.read.rows.count == 2_500)
        #expect(run.read.batchSizes == [1_000, 1_000, 500])
        #expect(run.read.rows.last == [.text("row 2499")])
    }

    @Test("At Read-Only the export reads inside a read-only transaction through the extended protocol")
    func readOnlyExportIsWrapped() async throws {
        let server = try FakePostgreSQLServer(replies: ["SELECT n FROM big": .rows(3)])
        let run = try await Self.run(on: server) { driver in
            try await Self.collect(driver.exportRows(query: "SELECT n FROM big", readOnly: true))
        }

        #expect(run.read.rows.count == 3)
        #expect(Array(run.served.queries.suffix(4)) == [
            LibPQReadOnlyTransaction.begin, "SELECT n FROM big", LibPQReadOnlyTransaction.end, "SELECT 2",
        ])
        #expect(run.served.extendedQueries == ["SELECT n FROM big"])
    }

    @Test("The grid shows a boolean as true or false and a bytea by its byte count (D7)")
    func gridDecodesBooleans() async throws {
        let server = try FakePostgreSQLServer(replies: [Self.report: .typed(Self.typedColumns, rows: Self.typedRows)])
        let run = try await Self.run(on: server) { driver in
            var rows: [Row] = []
            for try await element in driver.executeStreaming(query: Self.report, options: StreamOptions(maxRows: 100)) {
                if case .row(let row) = element { rows.append(row) }
            }
            return rows
        }

        #expect(run.read.map { $0.cells.map(Self.shape) } == [
            ["text true", "binary 2", "null"],
            ["text false", "binary 0", "text x"],
        ])
    }

    private static func shape(_ cell: Cell) -> String {
        switch cell {
        case .null: "null"
        case .text(let value): "text \(value)"
        case .truncatedText(let prefix, _, _): "truncated \(prefix)"
        case .binary(let count, _): "binary \(count)"
        }
    }

    @Test("A statement's text result reads booleans as the Mac does and keeps a bytea's hex form")
    func executeDecodesBooleans() async throws {
        let server = try FakePostgreSQLServer(replies: [Self.report: .typed(Self.typedColumns, rows: Self.typedRows)])
        let run = try await Self.run(on: server) { driver in try await driver.execute(query: Self.report) }

        #expect(run.read.rows == [["true", "\\x01ff", nil], ["false", "\\x", "x"]])
        #expect(run.read.columns.map(\.typeName) == ["boolean", "bytea", "text"])
    }

    @Test("A catalog read keeps every row, past the 100,000 the text result keeps, under the pinned search path")
    func catalogQueryHasNoCap() async throws {
        let statement = "SELECT n FROM pg_catalog.pg_class"
        let sent = PostgreSQLCatalogSearchPath.pinned + statement
        let server = try FakePostgreSQLServer(replies: [sent: .rows(100_001)])
        let run = try await Self.run(on: server) { driver in try await driver.catalogQuery(statement) }

        #expect(run.read.rows.count == 100_001)
        #expect(!run.read.isTruncated)
        #expect(run.served.queries.contains(sent))
    }

    @Test("A schema-relative read puts that schema on the path")
    func relativeCatalogRead() async throws {
        let statement = "SELECT pg_catalog.format_type(1, 2)"
        let sent = PostgreSQLCatalogSearchPath.relative(to: "sales") + statement
        let server = try FakePostgreSQLServer(replies: [sent: .rows(1)])
        let run = try await Self.run(on: server) { driver in
            try await driver.catalogCells(statement, namesRelativeTo: "sales")
        }

        #expect(run.read.rows == [[.text("row 0")]])
        #expect(run.served.queries.contains(sent))
    }

    @Test("A catalog read with parameters sets the path on its own inside a block it opens, then binds")
    func parameterizedCatalogRead() async throws {
        let statement = "SELECT n FROM pg_catalog.pg_class WHERE relname = $1"
        let server = try FakePostgreSQLServer(replies: [statement: .rows(1)])
        let run = try await Self.run(on: server) { driver in try await driver.catalogQuery(statement, parameters: ["t"]) }

        #expect(run.read.rows.count == 1)
        #expect(Array(run.served.queries.suffix(5)) == [
            "BEGIN", PostgreSQLCatalogSearchPath.pinned, statement, "ROLLBACK", "SELECT 2",
        ])
        #expect(run.served.extendedQueries == [statement])
    }

    @Test("A Redshift catalog read runs as it is, as on the Mac")
    func redshiftCatalogReadIsNotPinned() async throws {
        let statement = "SELECT n FROM pg_catalog.pg_class"
        let server = try FakePostgreSQLServer(replies: [statement: .rows(2)])
        let run = try await Self.run(on: server, databaseType: .redshift) { driver in
            try await driver.catalogQuery(statement)
        }

        #expect(run.read.rows.count == 2)
        #expect(!run.served.queries.contains { $0.hasPrefix("SET LOCAL search_path") })
    }

    @Test("Bound values go through the extended protocol, one statement")
    func executeParameterizedBinds() async throws {
        let insert = "INSERT INTO \"public\".\"t\" (\"a\", \"b\") VALUES ($1, $2)"
        let server = try FakePostgreSQLServer()
        let run = try await Self.run(on: server) { driver in
            try await driver.executeParameterized(query: insert, parameters: [.text("x"), .bytes(Data([1]))], typeNames: nil)
        }

        #expect(run.read.rowsAffected == 0)
        #expect(run.served.extendedQueries == [insert])
    }

    @Test("COPY FROM STDIN sends every piece as CopyData, then ends the copy")
    func copySendsEveryPiece() async throws {
        let copy = "COPY public.t (a, b) FROM stdin"
        let server = try FakePostgreSQLServer(replies: [copy: .copyIn])
        let pieces = CopyPieces(["1\talpha\n", "2\tbe", "ta\n"])
        let run = try await Self.run(on: server) { driver in
            try await driver.copyFromStandardInput(statement: copy, rows: PluginCopyData(read: { try pieces.next() }))
        }

        #expect(run.read.rowsAffected == 2)
        #expect(String(decoding: run.served.copied, as: UTF8.self) == "1\talpha\n2\tbeta\n")
        #expect(run.served.copyFailure == nil)
    }

    @Test("A source that fails ends the copy with CopyFail and its own error")
    func copySourceFailureFailsTheCopy() async throws {
        let copy = "COPY public.t (a) FROM stdin"
        let server = try FakePostgreSQLServer(replies: [copy: .copyIn])
        let run = try await Self.run(on: server) { driver in
            await #expect(throws: CopySourceFailure.self) {
                _ = try await driver.copyFromStandardInput(
                    statement: copy, rows: PluginCopyData(read: { throw CopySourceFailure() })
                )
            }
        }

        #expect(run.served.copyFailure == LibPQCopyIn.sourceFailedReason)
    }

    @Test("Redshift refuses COPY FROM STDIN before anything is sent, as on the Mac")
    func redshiftRefusesCopy() async throws {
        let driver = PostgreSQLDriver(
            host: "127.0.0.1", port: 1, user: "app", password: "", database: "app", databaseType: .redshift
        )
        await #expect(throws: PluginDriverUnsupportedOperation.copyFromStandardInput) {
            _ = try await driver.copyFromStandardInput(statement: "COPY t FROM stdin", rows: PluginCopyData(read: { nil }))
        }
    }

    @Test("Foreign key checks switch through session_replication_role on PostgreSQL and not on Redshift")
    func foreignKeyCheckStatements() {
        let postgres = PostgreSQLDriver(host: "h", port: 5_432, user: "u", password: "", database: "d")
        let redshift = PostgreSQLDriver(host: "h", port: 5_439, user: "u", password: "", database: "d", databaseType: .redshift)

        #expect(postgres.foreignKeyCheckStatements(enabled: false) == PostgreSQLForeignKeyChecks.disableStatements)
        #expect(postgres.foreignKeyCheckStatements(enabled: true) == PostgreSQLForeignKeyChecks.enableStatements)
        #expect(redshift.foreignKeyCheckStatements(enabled: false).isEmpty)
    }

    // MARK: - Helpers

    private struct CopySourceFailure: Error {}

    private final class CopyPieces: Sendable {
        private let pieces: OSAllocatedUnfairLock<[Data]>

        init(_ pieces: [String]) {
            self.pieces = OSAllocatedUnfairLock(initialState: pieces.map { Data($0.utf8) })
        }

        func next() throws -> Data? {
            pieces.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }
    }

    private struct Collected {
        var columns: [String] = []
        var typeNames: [String] = []
        var rows: [[PluginCellValue]] = []
        var batchSizes: [Int] = []
    }

    private struct Run<Value> {
        let read: Value
        let served: FakePostgreSQLServer.Session
    }

    private static func collect(_ stream: AsyncThrowingStream<PluginStreamElement, Error>) async throws -> Collected {
        var collected = Collected()
        for try await element in stream {
            switch element {
            case .header(let header):
                collected.columns = header.columns
                collected.typeNames = header.columnTypeNames
            case .rows(let rows):
                collected.rows += rows
                collected.batchSizes.append(rows.count)
            }
        }
        return collected
    }

    // Connects, runs `body`, sends `SELECT 2` so the server shows what came after it, and disconnects.
    private static func run<Value>(
        on server: FakePostgreSQLServer,
        databaseType: DatabaseType = .postgresql,
        _ body: (PostgreSQLDriver) async throws -> Value
    ) async throws -> Run<Value> {
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = PostgreSQLDriver(
            host: "127.0.0.1", port: server.port, user: "app", password: "app-password", database: "app",
            databaseType: databaseType
        )
        try await driver.connect()
        let read = try await body(driver)
        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()
        return Run(read: read, served: await session)
    }
}

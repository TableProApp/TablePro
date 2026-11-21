import Foundation
import os
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProOracleCore
import TableProPluginKit
import Testing

// A plugin read the test feeds. Only the grid holds its rows, so letting them go ends it, as the plugin's own read ends.
nonisolated private final class PluginRead: @unchecked Sendable {
    let feed: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    let released: AsyncStream<Void>
    private let lock = NSLock()
    private var rows: AsyncThrowingStream<PluginStreamElement, Error>?

    init() {
        let (rows, feed) = AsyncThrowingStream<PluginStreamElement, Error>.makeStream()
        let (released, signal) = AsyncStream<Void>.makeStream()
        feed.onTermination = { termination in
            if case .cancelled = termination {
                signal.yield()
                signal.finish()
            }
        }
        self.rows = rows
        self.feed = feed
        self.released = released
    }

    func open() -> AsyncThrowingStream<PluginStreamElement, Error> {
        lock.withLock {
            defer { rows = nil }
            return rows ?? AsyncThrowingStream { $0.finish() }
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct OracleBackedDriverTests {
    private static let header = PluginStreamElement.header(PluginStreamHeader(
        columns: ["ID", "NOTE", "DATA"], columnTypeNames: ["NUMBER", "CLOB", "BLOB"]
    ))

    private static func makeDriver(_ connection: DatabaseConnection, password: String? = nil) throws -> OracleBackedDriver {
        try #require(try IOSDriverFactory().createDriver(for: connection, password: password) as? OracleBackedDriver)
    }

    private static func drain(_ stream: AsyncThrowingStream<StreamElement, Error>) async throws -> [StreamElement] {
        var elements: [StreamElement] = []
        for try await element in stream {
            elements.append(element)
        }
        return elements
    }

    private static func rows(of elements: [StreamElement]) -> [Row] {
        elements.compactMap { element -> Row? in
            if case .row(let row) = element { return row }
            return nil
        }
    }

    @Test("The factory hands the connection's sign-in, identifier, role, encryption and connect timeout to the plugin")
    func factoryHandsTheConnectionOver() throws {
        let connection = DatabaseConnection(
            type: .oracle,
            host: "db.example.com",
            port: 1_522,
            username: "hr",
            database: "ORCL",
            additionalFields: [
                OracleConnectionOptions.AdditionalFieldKey.connectionType: OracleConnectionOptions.IdentifierMode.sid.rawValue,
                OracleConnectionOptions.AdditionalFieldKey.sid: "XE",
                OracleConnectionOptions.AdditionalFieldKey.role: OracleConnectionOptions.Role.sysdba.rawValue,
                OracleConnectionOptions.AdditionalFieldKey.networkEncryption:
                    OracleConnectionOptions.NetworkEncryption.required.rawValue,
                DatabaseConnection.connectTimeoutSecondsKey: "12",
            ]
        )

        let driver = try Self.makeDriver(connection, password: "secret")
        let config = try #require(driver.plugin as? OraclePluginDriver).config

        #expect(config.host == "db.example.com")
        #expect(config.port == 1_522)
        #expect(config.username == "hr")
        #expect(config.password == "secret")
        #expect(OracleConnectionOptions.identifierMode(from: config.additionalFields) == .sid)
        #expect(config.additionalFields[OracleConnectionOptions.AdditionalFieldKey.sid] == "XE")
        #expect(OracleConnectionOptions.role(from: config.additionalFields) == .sysdba)
        #expect(OracleConnectionOptions.networkEncryption(from: config.additionalFields) == .required)
        #expect(OracleConnectionOptions.loginTimeoutSeconds(from: config.additionalFields) == 12)
        #expect(driver.dialedHosts == ["db.example.com"])
    }

    @Test("A connection with no fields signs in by service name with a normal role")
    func defaultsToServiceName() throws {
        let driver = try Self.makeDriver(DatabaseConnection(type: .oracle, host: "db.example.com", port: 1_521))
        let config = try #require(driver.plugin as? OraclePluginDriver).config

        #expect(OracleConnectionOptions.identifierMode(from: config.additionalFields) == .service)
        #expect(OracleConnectionOptions.role(from: config.additionalFields) == .normal)
    }

    // The driver lists columns through the plugin's catalog and `ColumnInfo(from:)`.
    @Test("Identity and virtual columns read as auto-increment and generated, which the new row form leaves to the server")
    func identityAndVirtualColumnsAreFlagged() async throws {
        let release = OracleServerRelease(major: 23)
        let reads = RecordedCatalogReads([
            OracleSchemaQueries.columns(schema: "APP", table: "ORDERS", release: release): [
                ["ID", "NUMBER", "22", "10", "0", "N", "Y", nil, "NO", "YES", "NO", "NO", "ALWAYS"],
                ["TOTAL", "NUMBER", "22", nil, nil, "Y", "N", "\"PRICE\"*2", "YES", "NO", "NO", "NO", nil],
                ["NOTE", "VARCHAR2", "40", nil, nil, "Y", "N", nil, "NO", "NO", "NO", "NO", nil, "40", "B"],
            ],
        ])
        let catalog = OracleExportCatalog(
            run: { statement in
                OracleRawResult(
                    columns: [],
                    rows: try reads.rows(statement).map { row in
                        row.map { cell -> OracleRawCell in
                            switch cell {
                            case .null: .null
                            case .text(let text): .string(text)
                            case .bytes(let data): .bytes(data)
                            }
                        }
                    },
                    affectedRows: 0,
                    isTruncated: false
                )
            },
            currentSchema: "APP",
            fallbackSchema: "APP",
            release: release,
            principalState: OSAllocatedUnfairLock(initialState: OraclePrincipalState()),
            coreError: { $0 as? OracleCoreError }
        )

        let columns = try await catalog.fetchColumns(table: "ORDERS", schema: "APP").enumerated().map { index, column in
            ColumnInfo(from: column, ordinalPosition: index)
        }

        let autoIncrementing = columns.map { $0.isAutoIncrement }
        let generated = columns.map { $0.isGenerated }
        #expect(autoIncrementing == [true, false, false])
        #expect(generated == [false, true, false])
    }

    @Test("Rows are edited through SQLBuilder, never the plugin's own writer")
    func editsStayOnSQLBuilder() throws {
        let driver: any DatabaseDriver = try Self.makeDriver(DatabaseConnection(type: .oracle, host: "db.example.com"))

        #expect(!(driver is any DriverRowWriting))
        #expect(RowLocator.identity(of: driver) == .keyColumns)
    }

    @Test("Stop on a session that never connected does nothing")
    func stopBeforeConnecting() async throws {
        try await Self.makeDriver(DatabaseConnection(type: .oracle, host: "db.example.com")).cancelCurrentQuery()
    }

    @Test("A long value is cut for display with a reference built from the key, and bytes stay a binary cell")
    func gridCutsEachRow() async throws {
        let read = PluginRead()
        read.feed.yield(Self.header)
        read.feed.yield(.rows([[.text("7"), .text(String(repeating: "x", count: 5_000)), .bytes(Data([0x01, 0x02]))]]))
        read.feed.finish()
        let options = StreamOptions(maxRows: 10, lazyContext: LazyContext(table: "NOTES", primaryKeyColumns: ["ID"]))

        let elements = try await Self.drain(OracleBackedDriver.gridRows(options: options) { read.open() })

        let row = try #require(Self.rows(of: elements).first)
        guard case .text(let id) = row.cells[0] else {
            Issue.record("the key should stay whole")
            return
        }
        #expect(id == "7")
        guard case .truncatedText(_, let totalBytes, let ref) = row.cells[1] else {
            Issue.record("the long value should be cut for display")
            return
        }
        #expect(totalBytes == 5_000)
        #expect(ref?.primaryKey == [PrimaryKeyComponent(column: "ID", value: "7")])
        guard case .binary(let count, _) = row.cells[2] else {
            Issue.record("bytes should arrive as a binary cell")
            return
        }
        #expect(count == 2)
    }

    @Test("A read stops at the cap, says so, and lets the plugin's read go")
    func gridStopsAtTheCap() async throws {
        let read = PluginRead()
        read.feed.yield(Self.header)
        for id in 1...3 {
            read.feed.yield(.rows([[.text(String(id)), .text("n"), .null]]))
        }

        let elements = try await Self.drain(OracleBackedDriver.gridRows(options: StreamOptions(maxRows: 2)) { read.open() })

        #expect(Self.rows(of: elements).count == 2)
        let reason = elements.compactMap { element -> TruncationReason? in
            if case .truncated(let reason) = element { return reason }
            return nil
        }.first
        guard case .rowCap(2) = reason else {
            Issue.record("the read should end at its row cap")
            return
        }
        for await _ in read.released { break }
    }

    @Test("Stop lets the plugin's read go")
    func stopReleasesTheRead() async throws {
        let read = PluginRead()
        read.feed.yield(Self.header)
        read.feed.yield(.rows([[.text("1"), .text("n"), .null]]))
        let (firstRow, sawRow) = AsyncStream<Void>.makeStream()
        let grid = OracleBackedDriver.gridRows(options: StreamOptions(maxRows: 10)) { read.open() }

        let reader = Task {
            for try await element in grid {
                if case .row = element { sawRow.yield() }
            }
        }
        for await _ in firstRow { break }
        reader.cancel()

        for await _ in read.released { break }
    }

    @Test("A failed read reports the plugin's error")
    func gridPassesTheErrorOn() async throws {
        let read = PluginRead()
        read.feed.yield(Self.header)
        read.feed.finish(throwing: OraclePluginError(core: .queryFailed("ORA-00942: table or view does not exist")))

        let error = await #expect(throws: OraclePluginError.self) {
            _ = try await Self.drain(OracleBackedDriver.gridRows(options: StreamOptions(maxRows: 10)) { read.open() })
        }

        #expect(error?.localizedDescription.contains("ORA-00942") == true)
    }
}

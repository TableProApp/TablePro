//
//  SQLExportReadScopeTests.swift
//  FormatPluginTests
//
//  The export reads on the user's own session, so the settings the driver pins for the read have to be put back
//  on every exit, and the dump declares the time zone only when the read was pinned to it.
//

import Foundation
import TableProPluginKit
import Testing

struct SQLExportReadScopeTests {
    private struct InjectedFailure: Error {}

    private enum OpenBehavior {
        case returns(PluginSessionScope?)
        case fails
    }

    private static let utcScope = PluginSessionScope(
        purpose: .verbatimRead,
        saved: [
            PluginSessionSetting(name: "sql_mode", value: "ANSI_QUOTES"),
            PluginSessionSetting(name: "time_zone", value: "SYSTEM"),
        ],
        applied: [
            PluginSessionSetting(name: "sql_mode", value: ""),
            PluginSessionSetting(name: "time_zone", value: "+00:00"),
        ])

    private final class RecordingDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId = "MySQL"
        private let readBehavior: OpenBehavior
        private let preserveBehavior: OpenBehavior
        private let failsStream: Bool
        private let failsClose: Bool
        private let onExecute: (@Sendable (String) -> Void)?
        private let afterLastRow: (@Sendable () -> Void)?

        private let lock = NSLock()
        private var recordedEvents: [String] = []
        private var recordedPurposes: [PluginSessionPurpose] = []
        private var recordedClosures: [PluginSessionScope] = []

        init(
            read readBehavior: OpenBehavior,
            preserve preserveBehavior: OpenBehavior = .returns(nil),
            failsStream: Bool = false,
            failsClose: Bool = false,
            onExecute: (@Sendable (String) -> Void)? = nil,
            afterLastRow: (@Sendable () -> Void)? = nil
        ) {
            self.readBehavior = readBehavior
            self.preserveBehavior = preserveBehavior
            self.failsStream = failsStream
            self.failsClose = failsClose
            self.onExecute = onExecute
            self.afterLastRow = afterLastRow
        }

        var events: [String] { lock.withLock { recordedEvents } }
        var openedPurposes: [PluginSessionPurpose] { lock.withLock { recordedPurposes } }
        var closedScopes: [PluginSessionScope] { lock.withLock { recordedClosures } }

        private func record(_ event: String) {
            lock.withLock { recordedEvents.append(event) }
        }

        func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
            lock.withLock {
                recordedEvents.append("open")
                recordedPurposes.append(purpose)
            }
            switch purpose == .preserve ? preserveBehavior : readBehavior {
            case .returns(let scope): return scope
            case .fails: throw InjectedFailure()
            }
        }

        func closeSessionScope(_ scope: PluginSessionScope) async throws {
            lock.withLock {
                recordedEvents.append("close")
                recordedClosures.append(scope)
            }
            if failsClose { throw InjectedFailure() }
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            record("rows")
            let failsStream = failsStream
            let afterLastRow = afterLastRow
            return AsyncThrowingStream { continuation in
                continuation.yield(.header(PluginStreamHeader(columns: ["id", "at"], columnTypeNames: ["INT", "TIMESTAMP"])))
                guard !failsStream else {
                    continuation.finish(throwing: InjectedFailure())
                    return
                }
                continuation.yield(.rows([[.text("1"), .text("2024-06-01 12:00:00")]]))
                afterLastRow?()
                continuation.finish()
            }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String {
            "CREATE TABLE `\(table)` (`id` int, `at` timestamp NULL)"
        }

        func execute(query: String) async throws -> PluginQueryResult {
            record(query)
            onExecute?(query)
            return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String {
            "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
        }

        func escapeStringLiteral(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }

        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    }

    private let table = PluginExportTable(
        name: "events", databaseName: "", tableType: "table", optionValues: [true, false, true], schema: nil)

    private func options(consistentSnapshot: Bool = false) -> SQLExportOptions {
        var options = SQLExportOptions()
        options.consistentSnapshot = consistentSnapshot
        return options
    }

    @Test("A read pinned to UTC declares UTC in the dump and restores the zone after it")
    func pinnedReadDeclaresItsZone() async throws {
        let source = RecordingDataSource(read: .returns(Self.utcScope))
        let dump = try await SQLExportHarness.shared.dump(tables: [table], dataSource: source).text

        #expect(dump.contains("/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;\n/*!40103 SET TIME_ZONE='+00:00' */;\n"))
        #expect(dump.contains("/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;"))
        #expect(source.openedPurposes == [.verbatimRead])
        #expect(source.closedScopes == [Self.utcScope])
    }

    @Test("A driver with no read scope gets a dump that declares no zone")
    func noScopeDeclaresNoZone() async throws {
        let source = RecordingDataSource(read: .returns(nil))
        let dump = try await SQLExportHarness.shared.dump(tables: [table], dataSource: source).text

        #expect(!dump.contains("TIME_ZONE"))
        #expect(dump.contains("SQL_MODE='NO_AUTO_VALUE_ON_ZERO'"))
        #expect(source.closedScopes.isEmpty)
    }

    @Test("A read scope that fails to open leaves the export as it was, with no zone declared")
    func failedOpenExportsAsBefore() async throws {
        let source = RecordingDataSource(read: .fails)
        let output = try await SQLExportHarness.shared.dump(tables: [table], dataSource: source)

        #expect(!output.text.contains("TIME_ZONE"))
        #expect(output.text.contains("INSERT INTO `events`"))
        #expect(output.result.warnings.isEmpty)
        #expect(source.closedScopes.isEmpty)
    }

    private func scopedTable(_ name: String, rowScope: PluginExportRowScope) -> PluginExportTable {
        PluginExportTable(
            name: name, databaseName: "", tableType: "table", optionValues: [true, false, true], schema: nil,
            kind: .table, rowScope: rowScope)
    }

    /// The filter is the user's SQL for their own session: under UTC a `NOW()` picks other rows than the grid showed.
    @Test("A row filter keeps the export on the user's session, so the dump declares no zone")
    func filteredExportOpensNoScope() async throws {
        let source = RecordingDataSource(read: .returns(Self.utcScope))
        let filtered = scopedTable("recent", rowScope: PluginExportRowScope(filter: "`at` > NOW() - INTERVAL 1 DAY"))
        let dump = try await SQLExportHarness.shared.dump(tables: [table, filtered], dataSource: source).text

        #expect(!source.openedPurposes.contains(.verbatimRead))
        #expect(source.closedScopes.isEmpty)
        #expect(!dump.contains("TIME_ZONE"))
        #expect(dump.contains("SQL_MODE='NO_AUTO_VALUE_ON_ZERO'"))
    }

    @Test(
        "A scope that runs no filter still reads under the read scope",
        arguments: [
            PluginExportRowScope(rowLimit: 10),
            PluginExportRowScope(columns: ["id"]),
            PluginExportRowScope(filter: "   "),
            PluginExportRowScope(filter: "id = 1; DROP TABLE events"),
        ]
    )
    func unfilteredNarrowingKeepsTheScope(rowScope: PluginExportRowScope) async throws {
        let source = RecordingDataSource(read: .returns(Self.utcScope))
        let dump = try await SQLExportHarness.shared.dump(
            tables: [scopedTable("events", rowScope: rowScope)], dataSource: source).text

        #expect(source.openedPurposes == [.verbatimRead])
        #expect(source.closedScopes == [Self.utcScope])
        #expect(dump.contains("/*!40103 SET TIME_ZONE='+00:00' */;"))
    }

    private static let plainModeLine = "/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;"
    private static let ansiQuotesModeLine =
        "/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO,ANSI_QUOTES' */;"

    private static func sessionProbe(sqlMode: String?) -> PluginSessionScope {
        PluginSessionScope(
            purpose: .preserve,
            saved: [
                PluginSessionSetting(name: "sql_mode", value: sqlMode),
                PluginSessionSetting(name: "time_zone", value: "SYSTEM"),
            ],
            applied: [])
    }

    private var filteredTable: PluginExportTable {
        scopedTable("recent", rowScope: PluginExportRowScope(filter: "`at` > NOW() - INTERVAL 1 DAY"))
    }

    /// A filtered export reads its DDL under the session's mode, and `SHOW CREATE TABLE` under `ANSI_QUOTES` spells
    /// identifiers with `"`, which the plain dump mode reads as strings.
    @Test(
        "A filtered export read under ANSI_QUOTES keeps ANSI_QUOTES in the dump's mode",
        arguments: [
            "ANSI_QUOTES",
            "REAL_AS_FLOAT,PIPES_AS_CONCAT,ANSI_QUOTES,IGNORE_SPACE,ONLY_FULL_GROUP_BY",
            "strict_trans_tables, ansi_quotes",
        ]
    )
    func filteredExportUnderANSIQuotes(sqlMode: String) async throws {
        let probe = Self.sessionProbe(sqlMode: sqlMode)
        let source = RecordingDataSource(read: .returns(Self.utcScope), preserve: .returns(probe))
        let dump = try await SQLExportHarness.shared.dump(tables: [filteredTable], dataSource: source).text

        #expect(dump.contains(Self.ansiQuotesModeLine))
        #expect(!dump.contains(Self.plainModeLine))
        #expect(source.openedPurposes == [.preserve])
        #expect(source.closedScopes == [probe])
        #expect(Array(source.events.prefix(3)) == ["open", "close", "rows"])
    }

    @Test(
        "A filtered export read without ANSI_QUOTES writes the plain mode",
        arguments: [nil, "", "STRICT_TRANS_TABLES,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION"] as [String?]
    )
    func filteredExportWithoutANSIQuotes(sqlMode: String?) async throws {
        let probe = Self.sessionProbe(sqlMode: sqlMode)
        let source = RecordingDataSource(read: .returns(Self.utcScope), preserve: .returns(probe))
        let dump = try await SQLExportHarness.shared.dump(tables: [filteredTable], dataSource: source).text

        #expect(dump.contains(Self.plainModeLine))
        #expect(source.openedPurposes == [.preserve])
        #expect(source.closedScopes == [probe])
    }

    @Test("A probe that fails or reads nothing writes the plain mode")
    func failedProbeWritesThePlainMode() async throws {
        let failing = RecordingDataSource(read: .returns(Self.utcScope), preserve: .fails)
        let failingDump = try await SQLExportHarness.shared.dump(tables: [filteredTable], dataSource: failing).text
        #expect(failingDump.contains(Self.plainModeLine))
        #expect(failing.closedScopes.isEmpty)

        let empty = RecordingDataSource(read: .returns(Self.utcScope), preserve: .returns(nil))
        let emptyDump = try await SQLExportHarness.shared.dump(tables: [filteredTable], dataSource: empty).text
        #expect(emptyDump.contains(Self.plainModeLine))
        #expect(empty.closedScopes.isEmpty)
    }

    /// The read scope pins `sql_mode` to '', so the DDL comes back with backticks whatever the session had.
    @Test("An unfiltered export reads under the read scope and writes the plain mode, without probing")
    func unfilteredExportWritesThePlainMode() async throws {
        let probe = Self.sessionProbe(sqlMode: "ANSI_QUOTES")
        let source = RecordingDataSource(read: .returns(Self.utcScope), preserve: .returns(probe))
        let dump = try await SQLExportHarness.shared.dump(tables: [table], dataSource: source).text

        #expect(dump.contains(Self.plainModeLine))
        #expect(source.openedPurposes == [.verbatimRead])
        #expect(source.closedScopes == [Self.utcScope])
    }

    @Test("A read scope that fails to open falls back to the session's own mode")
    func failedReadScopeProbesTheSession() async throws {
        let probe = Self.sessionProbe(sqlMode: "ANSI_QUOTES")
        let source = RecordingDataSource(read: .fails, preserve: .returns(probe))
        let dump = try await SQLExportHarness.shared.dump(tables: [table], dataSource: source).text

        #expect(dump.contains(Self.ansiQuotesModeLine))
        #expect(!dump.contains("TIME_ZONE"))
        #expect(source.openedPurposes == [.verbatimRead, .preserve])
        #expect(source.closedScopes == [probe])
    }

    @Test("The scope opens before the snapshot begins and closes after it ends")
    func scopeEnclosesTheSnapshot() async throws {
        let source = RecordingDataSource(read: .returns(Self.utcScope))
        _ = try await SQLExportHarness.shared.dump(
            tables: [table], dataSource: source, options: options(consistentSnapshot: true))

        #expect(source.events == ["open", "START TRANSACTION WITH CONSISTENT SNAPSHOT", "rows", "COMMIT", "close"])
    }

    @Test("The scope is closed once when the data phase fails")
    func closedOnceWhenTheDataPhaseFails() async throws {
        let source = RecordingDataSource(read: .returns(Self.utcScope), failsStream: true)

        await #expect(throws: InjectedFailure.self) {
            _ = try await SQLExportHarness.shared.dump(tables: [self.table], dataSource: source)
        }
        #expect(source.closedScopes == [Self.utcScope])
    }

    @Test("The scope is closed once when the export is stopped while it reads")
    func closedOnceOnCancellation() async throws {
        let progress = PluginExportProgress(progress: Progress(totalUnitCount: 1))
        let source = RecordingDataSource(read: .returns(Self.utcScope), afterLastRow: { progress.cancel() })

        await #expect(throws: (any Error).self) {
            _ = try await SQLExportHarness.shared.dump(
                tables: [self.table], dataSource: source, progress: progress)
        }
        #expect(source.closedScopes == [Self.utcScope])
    }

    /// The success path closes the scope before the publication point checks for a stop, and the stop then runs
    /// the failure path, which closes again unless the first close is remembered.
    @Test("The scope is closed once when the stop lands at the publication point")
    func closedOnceWhenStoppedAtThePublicationPoint() async throws {
        let progress = PluginExportProgress(progress: Progress(totalUnitCount: 1))
        let source = RecordingDataSource(
            read: .returns(Self.utcScope),
            onExecute: { query in
                if query == "COMMIT" { progress.cancel() }
            })

        await #expect(throws: (any Error).self) {
            _ = try await SQLExportHarness.shared.dump(
                tables: [self.table], dataSource: source,
                options: self.options(consistentSnapshot: true), progress: progress)
        }
        #expect(source.closedScopes == [Self.utcScope])
    }

    @Test("The scope is closed when the dump file cannot be created")
    func closedWhenTheWriterCannotStart() async throws {
        let source = RecordingDataSource(read: .returns(Self.utcScope))
        let tables = [table]
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("dump.sql")

        await #expect(throws: (any Error).self) {
            try await SQLExportHarness.shared.withPlugin { plugin in
                _ = try await plugin.export(
                    tables: tables,
                    dataSource: source,
                    destination: destination,
                    progress: PluginExportProgress(progress: Progress(totalUnitCount: 1)))
            }
        }
        #expect(source.closedScopes == [Self.utcScope])
    }

    @Test("A scope that fails to close does not fail an export that was written")
    func failedCloseIsNotAnExportFailure() async throws {
        let source = RecordingDataSource(read: .returns(Self.utcScope), failsClose: true)
        let output = try await SQLExportHarness.shared.dump(tables: [table], dataSource: source)

        #expect(output.text.contains("INSERT INTO `events`"))
        #expect(output.result.warnings.isEmpty)
        #expect(source.closedScopes == [Self.utcScope])
    }
}

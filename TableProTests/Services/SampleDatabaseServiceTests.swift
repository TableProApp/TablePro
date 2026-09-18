//
//  SampleDatabaseServiceTests.swift
//  TableProTests
//

import Foundation
import SQLite3
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
@Suite("SampleDatabaseService install/reset lifecycle")
struct SampleDatabaseServiceTests {
    private static let bundledMarker = Data("BUNDLED-CHINOOK-V1".utf8)

    private final class StubInspector: SampleDatabaseConnectionInspector, @unchecked Sendable {
        var sampleConnectionOpen = false
        func isSampleConnectionOpen(at fileURL: URL) -> Bool { sampleConnectionOpen }
    }

    private struct Harness {
        let service: SampleDatabaseService
        let bundledURL: URL
        let installedURL: URL
        let inspector: StubInspector
        let workingDirectory: URL

        func sidecarURL(_ suffix: String) -> URL {
            SampleSQLite.sidecarURL(of: installedURL, suffix: suffix)
        }

        func existingSidecarSuffixes() -> [String] {
            SampleSQLite.sidecarSuffixes.filter { suffix in
                FileManager.default.fileExists(atPath: sidecarURL(suffix).path)
            }
        }
    }

    private func makeDatabaseHarness() throws -> Harness {
        let harness = try makeHarness()
        try FileManager.default.removeItem(at: harness.bundledURL)
        try SampleSQLite.writeSampleDatabase(at: harness.bundledURL)
        return harness
    }

    private func makeHarness(skipBundleFile: Bool = false) throws -> Harness {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SampleDatabaseServiceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )

        let bundleDirectory = workingDirectory.appendingPathComponent("Bundle", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleDirectory,
            withIntermediateDirectories: true
        )
        let bundledURL = bundleDirectory.appendingPathComponent("Chinook.sqlite", isDirectory: false)
        if !skipBundleFile {
            try Self.bundledMarker.write(to: bundledURL)
        }

        let installedDirectory = workingDirectory.appendingPathComponent("Installed", isDirectory: true)
        let installedURL = installedDirectory.appendingPathComponent("Chinook.sqlite", isDirectory: false)
        let inspector = StubInspector()

        let service = SampleDatabaseService(
            bundledFileResolver: { skipBundleFile ? nil : bundledURL },
            fileManager: .default,
            connectionInspector: inspector,
            baseDirectoryProvider: { installedDirectory }
        )

        return Harness(
            service: service,
            bundledURL: bundledURL,
            installedURL: installedURL,
            inspector: inspector,
            workingDirectory: workingDirectory
        )
    }

    @Test("installIfNeeded copies the bundled file when nothing is installed")
    func installIfNeeded_copiesBundledFile_whenInstalledMissing() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        #expect(!FileManager.default.fileExists(atPath: harness.installedURL.path))
        try harness.service.installIfNeeded()

        let installedData = try Data(contentsOf: harness.installedURL)
        #expect(installedData == Self.bundledMarker)
    }

    @Test("installIfNeeded preserves user edits when an installed copy exists")
    func installIfNeeded_preservesEdits_whenInstalledExists() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        try harness.service.installIfNeeded()
        let edited = Data("USER-EDITED".utf8)
        try edited.write(to: harness.installedURL)

        try harness.service.installIfNeeded()

        let installedData = try Data(contentsOf: harness.installedURL)
        #expect(installedData == edited, "Existing installed file must not be overwritten")
    }

    @Test("resetToBundled overwrites the installed file with the bundled copy")
    func resetToBundled_overwritesInstalled() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        try harness.service.installIfNeeded()
        try Data("USER-EDITED".utf8).write(to: harness.installedURL)

        try harness.service.resetToBundled()

        let installedData = try Data(contentsOf: harness.installedURL)
        #expect(installedData == Self.bundledMarker)
    }

    @Test("resetToBundled throws connectionInUse when the sample is open and leaves its files alone")
    func resetToBundled_throwsConnectionInUse_whenConnectionOpen() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        try harness.service.installIfNeeded()
        let edited = Data("USER-EDITED".utf8)
        try edited.write(to: harness.installedURL)
        for suffix in SampleSQLite.sidecarSuffixes {
            try Data("LIVE\(suffix)".utf8).write(to: harness.sidecarURL(suffix))
        }
        harness.inspector.sampleConnectionOpen = true

        #expect(throws: SampleDatabaseError.connectionInUse) {
            try harness.service.resetToBundled()
        }

        let installedData = try Data(contentsOf: harness.installedURL)
        #expect(installedData == edited)
        for suffix in SampleSQLite.sidecarSuffixes {
            let sidecarData = try Data(contentsOf: harness.sidecarURL(suffix))
            #expect(sidecarData == Data("LIVE\(suffix)".utf8), "\(suffix) must survive a refused reset")
        }
    }

    @Test("resetToBundled removes the rollback journal, write-ahead log and shared-memory index")
    func resetToBundled_removesEverySidecar() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        try harness.service.installIfNeeded()
        for suffix in SampleSQLite.sidecarSuffixes {
            try Data("STALE\(suffix)".utf8).write(to: harness.sidecarURL(suffix))
        }

        try harness.service.resetToBundled()

        #expect(harness.existingSidecarSuffixes().isEmpty)
        let installedData = try Data(contentsOf: harness.installedURL)
        #expect(installedData == Self.bundledMarker)
    }

    @Test("resetToBundled leaves no write-ahead log to replay over the fresh copy")
    func resetToBundled_leavesNoWriteAheadLogToReplay() throws {
        let harness = try makeDatabaseHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        try harness.service.installIfNeeded()
        try SampleSQLite.stageCrashedWriteAheadLog(beside: harness.installedURL)
        let writeAheadLog = try Data(contentsOf: harness.sidecarURL("-wal"))
        try #require(writeAheadLog.count > SampleSQLite.writeAheadLogHeaderSize)

        try harness.service.resetToBundled()

        try expectPristineSample(harness)
    }

    @Test("resetToBundled leaves no hot journal to roll back into the fresh copy")
    func resetToBundled_leavesNoHotJournalToRollBack() throws {
        let harness = try makeDatabaseHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        try harness.service.installIfNeeded()
        try SampleSQLite.stageHotJournal(beside: harness.installedURL)
        let journal = try Data(contentsOf: harness.sidecarURL("-journal"))
        try #require(journal.starts(with: SampleSQLite.rollbackJournalMagic))

        try harness.service.resetToBundled()

        try expectPristineSample(harness)
    }

    @Test("installIfNeeded clears journal files a missing database left behind")
    func installIfNeeded_clearsJournalFilesOfMissingDatabase() throws {
        let harness = try makeDatabaseHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        try harness.service.installIfNeeded()
        try SampleSQLite.stageHotJournal(beside: harness.installedURL)
        let journal = try Data(contentsOf: harness.sidecarURL("-journal"))
        try #require(journal.starts(with: SampleSQLite.rollbackJournalMagic))
        try FileManager.default.removeItem(at: harness.installedURL)

        try harness.service.installIfNeeded()

        try expectPristineSample(harness)
    }

    @Test("installIfNeeded never touches the journal files of an installed database")
    func installIfNeeded_keepsJournalFilesOfInstalledDatabase() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        try harness.service.installIfNeeded()
        let live = Data("LIVE".utf8)
        try live.write(to: harness.sidecarURL("-journal"))
        try live.write(to: harness.sidecarURL("-wal"))

        try harness.service.installIfNeeded()

        let journal = try Data(contentsOf: harness.sidecarURL("-journal"))
        let writeAheadLog = try Data(contentsOf: harness.sidecarURL("-wal"))
        #expect(journal == live)
        #expect(writeAheadLog == live)
    }

    @Test("installIfNeeded throws bundleMissing when the bundle has no Chinook file")
    func installIfNeeded_throwsBundleMissing_whenBundleHasNoFile() throws {
        let harness = try makeHarness(skipBundleFile: true)
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        #expect(throws: SampleDatabaseError.bundleMissing) {
            try harness.service.installIfNeeded()
        }
    }

    private func expectPristineSample(_ harness: Harness) throws {
        #expect(harness.existingSidecarSuffixes().isEmpty)

        let report = try SampleSQLite.report(at: harness.installedURL)
        #expect(report.originalRows == SampleSQLite.rowCount)
        #expect(report.integrity == "ok")

        let installedData = try Data(contentsOf: harness.installedURL)
        let bundledData = try Data(contentsOf: harness.bundledURL)
        #expect(installedData == bundledData)
    }
}

private enum SampleSQLite {
    static let sidecarSuffixes = ["-journal", "-wal", "-shm"]
    static let rowCount = 3_000
    static let writeAheadLogHeaderSize = 32
    static let rollbackJournalMagic: [UInt8] = [0xD9, 0xD5, 0x05, 0xF9, 0x20, 0xA1, 0x63, 0xD7]

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Report {
        let originalRows: Int
        let integrity: String
    }

    static func sidecarURL(of databaseURL: URL, suffix: String) -> URL {
        URL(fileURLWithPath: databaseURL.path + suffix)
    }

    static func writeSampleDatabase(at url: URL) throws {
        try withDatabase(at: url) { database in
            try exec(database, "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)")
            try exec(
                database,
                """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(rowCount))
                INSERT INTO t SELECT i, 'original' FROM n
                """
            )
        }
    }

    static func report(at url: URL) throws -> Report {
        try withDatabase(at: url) { database in
            let count = try firstValue(database, "SELECT count(*) FROM t WHERE v = 'original'")
            guard let originalRows = Int(count) else {
                throw Failure(description: "count(*) returned \(count)")
            }
            let integrity = try firstValue(database, "PRAGMA integrity_check")
            return Report(originalRows: originalRows, integrity: integrity)
        }
    }

    static func stageCrashedWriteAheadLog(beside url: URL) throws {
        let writeAheadLogURL = sidecarURL(of: url, suffix: "-wal")
        let writeAheadLog = try withDatabase(at: url) { database in
            try exec(database, "PRAGMA journal_mode = WAL")
            try exec(database, "UPDATE t SET v = 'edited' WHERE id <= 500")
            return try Data(contentsOf: writeAheadLogURL)
        }
        try writeAheadLog.write(to: writeAheadLogURL)
    }

    static func stageHotJournal(beside url: URL) throws {
        let journalURL = sidecarURL(of: url, suffix: "-journal")
        let journal = try withDatabase(at: url) { database in
            try exec(database, "UPDATE t SET v = 'edited' WHERE id <= 1500")
            try exec(database, "BEGIN")
            try exec(database, "UPDATE t SET v = 'uncommitted'")
            let flushStatus = sqlite3_db_cacheflush(database)
            guard flushStatus == SQLITE_OK else {
                throw Failure(description: "sqlite3_db_cacheflush returned \(flushStatus)")
            }
            let journal = try Data(contentsOf: journalURL)
            try exec(database, "ROLLBACK")
            return journal
        }
        try journal.write(to: journalURL)
    }

    private static func withDatabase<Result>(
        at url: URL,
        _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        defer { sqlite3_close(handle) }
        guard status == SQLITE_OK, let handle else {
            throw Failure(description: "sqlite3_open_v2 returned \(status)")
        }
        return try body(handle)
    }

    private static func exec(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard status == SQLITE_OK else {
            throw Failure(description: message.map { String(cString: $0) } ?? "sqlite3_exec returned \(status)")
        }
    }

    private static func firstValue(_ database: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(description: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw Failure(description: String(cString: sqlite3_errmsg(database)))
        }
        return String(cString: text)
    }
}

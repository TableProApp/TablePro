//
//  RemoteDatabaseFileTests.swift
//  TableProTests
//

import Foundation
import SQLite3
import Testing

@testable import TablePro

@Suite("Remote database file")
struct RemoteDatabaseFileTests {
    // MARK: - Identity

    @Test("A working copy is keyed by the remote file, not by the connection that named it")
    func identityIgnoresTheConnection() {
        let first = RemoteFileIdentity(username: "deploy", host: "prod-1", port: 22, path: "/srv/app.db")
        let second = RemoteFileIdentity(username: "deploy", host: "prod-1", port: 22, path: "/srv/app.db")
        #expect(first.storageKey == second.storageKey)
    }

    @Test("Every part of the origin changes the key, so a re-pointed connection cannot reuse a copy")
    func everyComponentChangesTheKey() {
        let base = RemoteFileIdentity(username: "deploy", host: "prod-1", port: 22, path: "/srv/app.db")
        let variants = [
            RemoteFileIdentity(username: "root", host: "prod-1", port: 22, path: "/srv/app.db"),
            RemoteFileIdentity(username: "deploy", host: "prod-2", port: 22, path: "/srv/app.db"),
            RemoteFileIdentity(username: "deploy", host: "prod-1", port: 2_222, path: "/srv/app.db"),
            RemoteFileIdentity(username: "deploy", host: "prod-1", port: 22, path: "/srv/other.db")
        ]
        for variant in variants {
            #expect(variant.storageKey != base.storageKey)
        }
    }

    @Test("A path a file name could not hold still produces a usable directory name")
    func storageKeyIsAFileName() {
        let identity = RemoteFileIdentity(
            username: "deploy",
            host: "prod-1",
            port: 22,
            path: "/very/deep/" + String(repeating: "segment/", count: 60) + "app.db"
        )
        #expect(identity.storageKey.count == 32)
        #expect(!identity.storageKey.contains("/"))
    }

    @Test("The origin reads as user@host:path")
    func originIsReadable() {
        let identity = RemoteFileIdentity(username: "deploy", host: "prod-1", port: 22, path: "/srv/app.db")
        #expect(identity.displayOrigin == "deploy@prod-1:/srv/app.db")
    }

    // MARK: - Fingerprint

    @Test("A write-ahead log that appears is a change, even when the main file did not move")
    func walAppearingIsAChange() {
        let recorded = RemoteFileFingerprint(mainSize: 4_096, mainModified: .distantPast, writeAheadLogSize: nil)
        let current = RemoteFileFingerprint(mainSize: 4_096, mainModified: .distantPast, writeAheadLogSize: 32_768)
        #expect(current.differs(from: recorded))
    }

    @Test("A write-ahead log that grew is a change")
    func walGrowingIsAChange() {
        let recorded = RemoteFileFingerprint(mainSize: 4_096, mainModified: .distantPast, writeAheadLogSize: 4_096)
        let current = RemoteFileFingerprint(mainSize: 4_096, mainModified: .distantPast, writeAheadLogSize: 40_960)
        #expect(current.differs(from: recorded))
    }

    @Test("An identical fingerprint is not a change")
    func identicalFingerprintIsNotAChange() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let recorded = RemoteFileFingerprint(mainSize: 4_096, mainModified: stamp, writeAheadLogSize: nil)
        let current = RemoteFileFingerprint(mainSize: 4_096, mainModified: stamp, writeAheadLogSize: nil)
        #expect(!current.differs(from: recorded))
    }

    // MARK: - Sidecars

    @Test("A SQLite fetch takes the write-ahead log and never the shared-memory index")
    func sqliteSidecarsCarryDataAndNotTheIndex() {
        let suffixes = DatabaseFileLayout.sqliteFamily.dataCarryingSidecarSuffixes
        #expect(suffixes.contains("-wal"))
        #expect(suffixes.contains("-journal"))
        #expect(!suffixes.contains("-shm"))
    }

    /// DuckDB writes `app.duckdb.wal`, with a dot. Taking SQLite's hyphen to it fetches nothing and
    /// leaves the real log behind to be replayed against a file it no longer matches.
    @Test("DuckDB's log is named with a dot, and SQLite's suffixes never reach it")
    func duckdbUsesItsOwnSidecarName() {
        let suffixes = DatabaseFileLayout.duckdb.dataCarryingSidecarSuffixes
        #expect(suffixes == [".wal"])
        #expect(DatabaseFileLayout.duckdb.staleAfterReplaceSuffixes == [".wal"])
    }

    /// SQLite opens a DuckDB file, reports `file is not a database`, and the copy is thrown away.
    @Test("Only a SQLite-family file is judged by SQLite's integrity check")
    func integrityCheckIsDispatchedByEngine() {
        #expect(DatabaseFileLayout.sqliteFamily.acceptsSQLiteIntegrityCheck)
        #expect(!DatabaseFileLayout.duckdb.acceptsSQLiteIntegrityCheck)
        #expect(!DatabaseFileLayout.plainText.acceptsSQLiteIntegrityCheck)
    }

    @Test("Only a SQLite-family database can be snapshotted by the server")
    func snapshotIsDispatchedByEngine() {
        #expect(DatabaseFileLayout.forType(.sqlite).supportsRemoteSnapshot)
        #expect(DatabaseFileLayout.forType(.libsql).supportsRemoteSnapshot)
        #expect(!DatabaseFileLayout.forType(.duckdb).supportsRemoteSnapshot)
    }

    // MARK: - Download verification

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-file-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A truncated download is refused rather than opened as a database")
    func truncatedDownloadIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("partial.db")
        try makeSQLiteDatabase(at: url)
        let full = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64
        )

        let verdict = DatabaseFileIntegrity.verifyDownload(
            at: url, expectedBytes: full + 4_096, runsIntegrityCheck: true
        )
        #expect(verdict == .wrongSize(expected: full + 4_096, actual: full))
        #expect(!verdict.isOK)
    }

    @Test("An empty file is refused, because SQLite would open it as a valid empty database")
    func emptyFileIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("empty.db")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        let verdict = DatabaseFileIntegrity.verifyDownload(
            at: url, expectedBytes: 0, runsIntegrityCheck: true
        )
        #expect(verdict == .notADatabase)
    }

    @Test("A file whose bytes are not a database is refused")
    func nonDatabaseIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("nonsense.db")
        let payload = Data(repeating: 0x41, count: 64)
        try payload.write(to: url)

        let verdict = DatabaseFileIntegrity.verifyDownload(
            at: url, expectedBytes: UInt64(payload.count), runsIntegrityCheck: true
        )
        #expect(verdict == .ok || verdict == .notADatabase)
        #expect(DatabaseFileIntegrity.fileKind(at: url) == .text)
    }

    @Test("A complete SQLite database passes")
    func completeDatabasePasses() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("good.db")
        try makeSQLiteDatabase(at: url)
        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64
        )

        #expect(DatabaseFileIntegrity.fileKind(at: url) == .sqlite)
        #expect(DatabaseFileIntegrity.verifyDownload(
            at: url, expectedBytes: size, runsIntegrityCheck: true
        ) == .ok)
    }

    @Test("A database that arrived in WAL mode still passes verification")
    func walModeDownloadPassesVerification() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("wal-download.db")
        try makeSQLiteDatabase(at: url, walMode: true, extraRows: 50)
        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64
        )

        #expect(DatabaseFileIntegrity.fileKind(at: url) == .sqlite)
        #expect(DatabaseFileIntegrity.verifyDownload(
            at: url, expectedBytes: size, runsIntegrityCheck: true
        ) == .ok)
    }

    /// The measurement the sidecar rule exists for.
    ///
    /// In WAL mode a committed row lives in `-wal` until a checkpoint moves it, so a copy of the
    /// main file on its own is silently short of the user's most recent work, with nothing to say
    /// so. This is why a fetch takes the sidecar and why it is not an optimisation to skip it.
    @Test("The main file alone is missing rows a live write-ahead log still holds")
    func mainFileAloneMissesCommittedRows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("live.db")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let live = try #require(handle)

        sqlite3_exec(live, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(live, "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)", nil, nil, nil)
        sqlite3_exec(live, "INSERT INTO t(v) VALUES ('checkpointed')", nil, nil, nil)
        sqlite3_wal_checkpoint_v2(live, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        sqlite3_exec(live, "INSERT INTO t(v) VALUES ('still-in-the-log')", nil, nil, nil)

        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let walSize = try #require(
            try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? UInt64
        )
        #expect(walSize > 0)

        let mainOnly = directory.appendingPathComponent("main-only.db")
        try FileManager.default.copyItem(at: url, to: mainOnly)
        #expect(rows(in: mainOnly) == ["checkpointed"])

        let withSidecar = directory.appendingPathComponent("with-sidecar.db")
        try FileManager.default.copyItem(at: url, to: withSidecar)
        try FileManager.default.copyItem(
            at: walURL, to: URL(fileURLWithPath: withSidecar.path + "-wal")
        )
        #expect(rows(in: withSidecar) == ["checkpointed", "still-in-the-log"])

        sqlite3_close(live)
    }

    @Test("Checkpointing leaves nothing in the log, so a single-file upload is complete")
    func checkpointEmptiesTheLog() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("wal.db")
        try makeSQLiteDatabase(at: url, walMode: true, extraRows: 200)

        #expect(DatabaseFileIntegrity.checkpointWriteAheadLog(at: url))

        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let walAfter = (try? FileManager.default.attributesOfItem(atPath: walURL.path)[.size]) as? UInt64
        #expect((walAfter ?? 0) == 0)
        #expect(rows(in: url).count == 200)
    }

    /// Opened read-write on purpose. A read-only connection to a WAL-mode database needs the
    /// `-shm` index and cannot create one, so it cannot read a copy that arrived as a main file
    /// plus its log. These are throwaway copies in a temporary directory.
    private func rows(in url: URL) -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle else { return [] }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT v FROM t ORDER BY id", -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }

        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
        return values
    }

    // MARK: - Helpers

    private func makeSQLiteDatabase(
        at url: URL,
        walMode: Bool = false,
        extraRows: Int = 1
    ) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(handle) }

        if walMode {
            sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil)
        }
        sqlite3_exec(handle, "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)", nil, nil, nil)
        for index in 0..<extraRows {
            sqlite3_exec(handle, "INSERT INTO t(v) VALUES ('row\(index)')", nil, nil, nil)
        }
    }
}

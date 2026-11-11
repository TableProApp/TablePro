import Foundation
import SQLite3
@testable import TablePro
import Testing

struct LocalSQLiteStoreOpenerTests {
    private let scratch: URL
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("local-store-opener-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    private func makeDatabase(at url: URL, rows: Int) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK else { return }
        defer { sqlite3_close_v2(db) }
        sqlite3_exec(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);", nil, nil, nil)
        sqlite3_exec(db, """
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(rows))
            INSERT INTO t (v) SELECT hex(randomblob(100)) FROM n;
            """, nil, nil, nil)
    }

    private func scalarInt(_ db: OpaquePointer, _ sql: String) -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func directoryEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: scratch.path(percentEncoded: false)).sorted()
    }

    @Test("A healthy store opens in place and nothing is set aside")
    func healthyStoreOpensInPlace() throws {
        let url = scratch.appendingPathComponent("store.db")
        makeDatabase(at: url, rows: 10)

        let opening = LocalSQLiteStoreOpener.open(at: url, now: fixedDate)
        guard case .opened(let handle, let setAside) = opening else {
            Issue.record("A healthy store did not open")
            return
        }
        defer { sqlite3_close_v2(handle) }

        #expect(setAside == nil)
        #expect(scalarInt(handle, "SELECT COUNT(*) FROM t;") == 10)
    }

    @Test("A file that is not a database is set aside unchanged and a fresh store opens in its place")
    func notADatabaseIsSetAside() throws {
        let url = scratch.appendingPathComponent("store.db")
        let damaged = Data(repeating: 0x2A, count: 4_096)
        try damaged.write(to: url)
        let expectedSetAside = LocalSQLiteStoreOpener.setAsideURL(for: url, at: fixedDate)

        let opening = LocalSQLiteStoreOpener.open(at: url, now: fixedDate)
        guard case .opened(let handle, let setAside) = opening else {
            Issue.record("No fresh store opened after setting the damaged one aside")
            return
        }
        defer { sqlite3_close_v2(handle) }

        let moved = try #require(setAside)
        #expect(moved.storeURL == url)
        #expect(moved.setAsideURL == expectedSetAside)
        #expect(try Data(contentsOf: moved.setAsideURL) == damaged)
        #expect(sqlite3_exec(handle, "CREATE TABLE fresh (id INTEGER);", nil, nil, nil) == SQLITE_OK)
        #expect(scalarInt(handle, "SELECT COUNT(*) FROM fresh;") == 0)
    }

    @Test("A database with a damaged page is set aside byte for byte")
    func damagedPageIsSetAside() throws {
        let url = scratch.appendingPathComponent("store.db")
        makeDatabase(at: url, rows: 2_000)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 4_096 * 2)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 4_096))
        try handle.close()
        let damaged = try Data(contentsOf: url)

        let opening = LocalSQLiteStoreOpener.open(at: url, now: fixedDate)
        guard case .opened(let fresh, let setAside) = opening else {
            Issue.record("No fresh store opened after setting the damaged one aside")
            return
        }
        defer { sqlite3_close_v2(fresh) }

        let moved = try #require(setAside)
        #expect(try Data(contentsOf: moved.setAsideURL) == damaged)
        #expect(scalarInt(fresh, "SELECT COUNT(*) FROM sqlite_master;") == 0)
    }

    @Test("A store that cannot be opened is reported unavailable and nothing is created")
    func unopenableStoreIsUnavailable() throws {
        let blocker = scratch.appendingPathComponent("not-a-directory")
        #expect(FileManager.default.createFile(atPath: blocker.path(percentEncoded: false), contents: Data()))

        let opening = LocalSQLiteStoreOpener.open(at: blocker.appendingPathComponent("store.db"), now: fixedDate)

        guard case .unavailable = opening else {
            Issue.record("A store under a file opened")
            return
        }
        #expect(try directoryEntries() == ["not-a-directory"])
    }

    @Test("A damaged store that cannot be moved stays where it is and nothing replaces it")
    func damagedStoreThatCannotMoveStaysInPlace() throws {
        let url = scratch.appendingPathComponent("store.db")
        let damaged = Data(repeating: 0x2A, count: 4_096)
        try damaged.write(to: url)
        let scratchPath = scratch.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratchPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratchPath) }

        let opening = LocalSQLiteStoreOpener.open(at: url, now: fixedDate)

        guard case .unavailable = opening else {
            Issue.record("A damaged store was replaced although it could not be set aside")
            return
        }
        #expect(try Data(contentsOf: url) == damaged)
        #expect(try directoryEntries() == ["store.db"])
    }

    @Test("A set-aside name already taken gets the next free one")
    func setAsideNameSkipsATakenOne() throws {
        let url = scratch.appendingPathComponent("store.db")
        let first = LocalSQLiteStoreOpener.setAsideURL(for: url, at: fixedDate)
        #expect(FileManager.default.createFile(atPath: first.path(percentEncoded: false) + "-wal", contents: Data()))

        let second = LocalSQLiteStoreOpener.setAsideURL(for: url, at: fixedDate)

        #expect(second != first)
        #expect(second.deletingLastPathComponent() == first.deletingLastPathComponent())
        #expect(second.lastPathComponent.hasPrefix("store.damaged-"))
        #expect(second.lastPathComponent.hasSuffix("-1.db"))
    }
}

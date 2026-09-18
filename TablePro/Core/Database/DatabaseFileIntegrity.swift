//
//  DatabaseFileIntegrity.swift
//  TablePro
//

import Foundation
import os
import SQLite3

/// Checks that a file the app just downloaded is the database it claims to be.
///
/// This exists because of what SQLite does when it is not: `sqlite3_open` on a missing or empty
/// path creates a valid, empty database and reports success. A download that was cancelled,
/// truncated by a dropped session, or aimed at the wrong path would therefore open cleanly, show
/// zero tables, and be indistinguishable from a database that really is empty. Writing that back
/// destroys the remote file, and every step up to it reports success.
///
/// A byte count is not enough on its own either: SFTP writes a file front to back, so a partial
/// download carries an intact header and a plausible prefix.
enum DatabaseFileIntegrity {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RemoteDatabaseFile")

    /// The 16 bytes every SQLite database starts with, including the trailing NUL.
    private static let sqliteMagic = Array("SQLite format 3\u{0}".utf8)

    /// DuckDB writes this at offset 8 of its first page.
    private static let duckdbMagic = Array("DUCK".utf8)

    enum Verdict: Equatable {
        case ok
        case wrongSize(expected: UInt64, actual: UInt64)
        case notADatabase
        case corrupt(String)

        var isOK: Bool { self == .ok }
    }

    /// Verifies a downloaded artifact against what the server said it was sending.
    ///
    /// `expectedBytes` is the size reported by the remote stat, and `expectedSHA256` the hash of
    /// what actually arrived. Both are compared before the file is treated as a database at all,
    /// because a size mismatch names a truncated transfer more precisely than any parse can.
    static func verifyDownload(
        at url: URL,
        expectedBytes: UInt64,
        runsIntegrityCheck: Bool
    ) -> Verdict {
        let actual = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
        guard let actual else { return .notADatabase }
        guard actual == expectedBytes else {
            return .wrongSize(expected: expectedBytes, actual: actual)
        }
        guard actual > 0 else { return .notADatabase }
        guard let kind = fileKind(at: url) else { return .notADatabase }

        guard runsIntegrityCheck, kind == .sqlite else { return .ok }
        return integrityCheck(at: url)
    }

    enum FileKind: Equatable {
        case sqlite
        case duckdb
        case text
    }

    /// Reads enough of the first page to tell what wrote the file. A ledger is plain text and has
    /// no magic, so anything that is not a known binary format is reported as text rather than
    /// rejected.
    static func fileKind(at url: URL) -> FileKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 32), !head.isEmpty else { return nil }

        let bytes = [UInt8](head)
        if bytes.count >= sqliteMagic.count, Array(bytes.prefix(sqliteMagic.count)) == sqliteMagic {
            return .sqlite
        }
        if bytes.count >= 12, Array(bytes[8..<12]) == duckdbMagic {
            return .duckdb
        }
        return .text
    }

    /// Runs `PRAGMA integrity_check` and reports the first thing it complains about.
    ///
    /// Opened read-only and with an immutable URI so the check cannot itself create, modify, or
    /// replay a journal against the file it is inspecting.
    static func integrityCheck(at url: URL) -> Verdict {
        var handle: OpaquePointer?
        let uri = "file:\(url.path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let handle
        else {
            if let handle { sqlite3_close(handle) }
            return .notADatabase
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA integrity_check(1)", -1, &statement, nil) == SQLITE_OK else {
            return .corrupt(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            return .corrupt(String(cString: sqlite3_errmsg(handle)))
        }
        let result = String(cString: text)
        guard result == "ok" else {
            Self.logger.error("integrity_check on the working copy said \(result, privacy: .public)")
            return .corrupt(result)
        }
        return .ok
    }

    /// Folds a write-ahead log back into the main file so a single-file upload carries every
    /// committed row.
    ///
    /// A driver that implements `closeAndFlush()` has already done this. Running it again costs one
    /// open on a file nobody holds and closes the gap for a driver that has not, which is the
    /// difference between uploading the user's edits and uploading the state before them.
    @discardableResult
    static func checkpointWriteAheadLog(at url: URL) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA wal_checkpoint(TRUNCATE)", -1, &statement, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

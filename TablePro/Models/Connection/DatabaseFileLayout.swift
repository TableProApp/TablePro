//
//  DatabaseFileLayout.swift
//  TablePro
//

import Foundation

/// What an engine puts on disk beside its database, and how a copy of it can be checked.
///
/// Engines do not agree on any of this. SQLite writes `app.db-wal`; DuckDB writes `app.duckdb.wal`,
/// with a dot rather than a hyphen. A single hardcoded suffix list therefore fetches the wrong file
/// for one of them, which means fetching a database without the committed rows still in its log and
/// then leaving that log behind to be replayed against a file it no longer matches.
enum DatabaseFileLayout: Sendable, Equatable {
    case sqliteFamily
    case duckdb
    case plainText

    static func forType(_ type: DatabaseType) -> DatabaseFileLayout {
        if type == .sqlite || type == .libsql { return .sqliteFamily }
        if type == .duckdb { return .duckdb }
        return .plainText
    }

    /// Suffixes that can hold committed data and must travel with the main file.
    ///
    /// `-shm` is deliberately absent from the SQLite set: it is a rebuildable index into the log,
    /// and a stale one is worse than none.
    var dataCarryingSidecarSuffixes: [String] {
        switch self {
        case .sqliteFamily: return ["-wal", "-journal"]
        case .duckdb: return [".wal"]
        case .plainText: return []
        }
    }

    /// Suffixes that are rebuilt from the main file and must be cleared after it is replaced, so a
    /// reader cannot apply a log that belongs to the file that used to be there.
    var staleAfterReplaceSuffixes: [String] {
        switch self {
        case .sqliteFamily: return ["-wal", "-shm"]
        case .duckdb: return [".wal"]
        case .plainText: return []
        }
    }

    /// Whether SQLite's own `integrity_check` can speak for this file. It cannot for a DuckDB
    /// database: SQLite opens it, reports `file is not a database`, and the copy is thrown away.
    var acceptsSQLiteIntegrityCheck: Bool { self == .sqliteFamily }

    /// Whether the server can be asked for a consistent snapshot with `VACUUM INTO`.
    var supportsRemoteSnapshot: Bool { self == .sqliteFamily }
}

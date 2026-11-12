//
//  QueryTabVersionStorage.swift
//  TablePro
//

import Combine
import Foundation
import os
import SQLite3

internal enum QueryTabVersionReason: Int, Sendable, CaseIterable {
    case run = 0
    case idle = 1
    case beforeReplace = 2
    case beforeRestore = 3
}

internal struct QueryTabVersionSummary: Sendable, Equatable, Identifiable {
    let id: Int64
    let reason: QueryTabVersionReason
    let savedAt: Date
}

internal struct QueryTabVersion: Sendable, Equatable {
    let summary: QueryTabVersionSummary
    let query: String
}

// Device-local and never synced. Rows outlive a closed tab, since Reopen Closed Tab brings the same tab id back.
internal actor QueryTabVersionStorage {
    static let shared = QueryTabVersionStorage()
    static let retainedVersionCount = 50
    static let maximumRetentionDays = 30
    static let idleCoalescingWindow: TimeInterval = 5 * 60

    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryTabVersionStorage")
    private static let secondsPerDay: TimeInterval = 86_400

    private struct DatabaseHandle: @unchecked Sendable {
        var pointer: OpaquePointer?
    }

    private struct NewestRow {
        let id: Int64
        let reason: QueryTabVersionReason?
        let idleSince: Date?
        let hasSameText: Bool
    }

    private var dbHandle = DatabaseHandle()
    private var isPrepared = false
    private let databaseURL: URL
    private let removeDatabaseOnDeinit: Bool
    private let now: @Sendable () -> Date
    private let historyMaxDays: @Sendable () -> Int
    private let announce: @Sendable (UUID?) -> Void
    private let reader: QueryTabVersionReader

    private var db: OpaquePointer? {
        if !isPrepared {
            isPrepared = true
            setupDatabase()
        }
        return dbHandle.pointer
    }

    init(
        databaseURL: URL = QueryTabVersionStorage.defaultDatabaseURL(),
        now: @escaping @Sendable () -> Date = Date.init,
        historyMaxDays: @escaping @Sendable () -> Int = { AppSettingsStorage.shared.loadHistory().maxDays },
        announce: @escaping @Sendable (UUID?) -> Void = { tabId in
            Task { @MainActor in AppEvents.shared.queryTabVersionsDidUpdate.send(tabId) }
        },
        removeDatabaseOnDeinit: Bool = false
    ) {
        self.databaseURL = databaseURL
        self.now = now
        self.historyMaxDays = historyMaxDays
        self.announce = announce
        self.removeDatabaseOnDeinit = removeDatabaseOnDeinit
        reader = QueryTabVersionReader(databaseURL: databaseURL)
    }

    static func defaultDatabaseURL() -> URL {
        let directory = AppStorageEnvironment.shared.applicationSupportRoot.appendingPathComponent("TablePro")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("query_tab_versions.db")
    }

    deinit {
        if let pointer = dbHandle.pointer {
            sqlite3_close_v2(pointer)
        }
        reader.close()
        if removeDatabaseOnDeinit {
            let path = databaseURL.path(percentEncoded: false)
            try? FileManager.default.removeItem(atPath: path)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
    }

    // A shorter Query History window applies here too: this store keeps text the user deleted.
    static func retentionDays(historyMaxDays: Int) -> Int {
        historyMaxDays > 0 ? min(maximumRetentionDays, historyMaxDays) : maximumRetentionDays
    }

    static func isRecordable(_ text: String) -> Bool {
        (text as NSString).length <= TabQueryContent.maxPersistableQuerySize
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated var retentionDays: Int {
        Self.retentionDays(historyMaxDays: historyMaxDays())
    }

    nonisolated func summaries(
        tabId: UUID,
        limit: Int = QueryTabVersionStorage.retainedVersionCount
    ) -> [QueryTabVersionSummary] {
        reader.summaries(tabId: tabId, savedSince: cutoff(before: now()), limit: limit)
    }

    nonisolated func version(id: Int64, tabId: UUID) -> QueryTabVersion? {
        reader.version(id: id, tabId: tabId, savedSince: cutoff(before: now()))
    }

    @discardableResult
    func record(tabId: UUID, connectionId: UUID, text: String, reason: QueryTabVersionReason) -> Bool {
        guard Self.isRecordable(text), let db else { return false }
        let savedAt = now()
        let keptSince = cutoff(before: savedAt)
        let newest = newestRow(tabId: tabId, comparedWith: text, savedSince: keptSince, db: db)
        if let newest, newest.hasSameText {
            // The idle row already holds this text; sealing it keeps the next pause from overwriting it.
            guard reason != .idle, newest.reason == .idle else { return false }
            return sealRow(newest.id, tabId: tabId, reason: reason, db: db)
        }

        let written: Bool
        if reason == .idle, let newest, newest.reason == .idle, let idleSince = newest.idleSince,
           savedAt.timeIntervalSince(idleSince) < Self.idleCoalescingWindow {
            written = replaceRow(newest.id, connectionId: connectionId, text: text, savedAt: savedAt, db: db)
        } else {
            written = insertRow(
                tabId: tabId,
                connectionId: connectionId,
                text: text,
                reason: reason,
                savedAt: savedAt,
                db: db
            )
        }
        guard written else {
            Self.logger.error("A query tab version could not be written")
            return false
        }
        trim(tabId: tabId, savedBefore: keptSince, db: db)
        announce(tabId)
        return true
    }

    @discardableResult
    func removeVersions(forConnection connectionId: UUID) -> Bool {
        guard let db else { return false }
        let removed = run("DELETE FROM tab_versions WHERE connection_id = ?;", db: db) { statement in
            Self.bind(connectionId.uuidString, to: statement, at: 1)
        }
        if removed { truncateLog(db) }
        if removed { announce(nil) }
        return removed
    }

    @discardableResult
    func removeAll() -> Bool {
        guard let db else { return false }
        let removed = run("DELETE FROM tab_versions;", db: db) { _ in }
        if removed { truncateLog(db) }
        if removed { announce(nil) }
        return removed
    }

    // A checkpoint alone leaves deleted text in the -wal file until its frames are reused.
    private func truncateLog(_ db: OpaquePointer) {
        _ = run("PRAGMA wal_checkpoint(TRUNCATE);", db: db) { _ in }
    }

    // MARK: - Setup

    private static let schemaStatements = [
        "PRAGMA journal_mode=WAL;",
        "PRAGMA synchronous=NORMAL;",
        // Clear History is a privacy command, so deleted text is overwritten rather than left in free pages.
        "PRAGMA secure_delete=ON;",
        """
        CREATE TABLE IF NOT EXISTS tab_versions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tab_id TEXT NOT NULL,
            connection_id TEXT NOT NULL,
            query TEXT NOT NULL,
            reason INTEGER NOT NULL,
            saved_at REAL NOT NULL,
            idle_since REAL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_tab_versions_tab ON tab_versions(tab_id, id);",
        "CREATE INDEX IF NOT EXISTS idx_tab_versions_connection ON tab_versions(connection_id);",
        "CREATE INDEX IF NOT EXISTS idx_tab_versions_saved ON tab_versions(saved_at);",
    ]

    private func setupDatabase() {
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard case .opened(let pointer, let setAside) = LocalSQLiteStoreOpener.open(at: databaseURL, now: now()) else {
            Self.logger.error("The query tab versions database could not be opened")
            return
        }
        dbHandle.pointer = pointer
        // The reader may hold the file a damaged store was moved to.
        reader.close()
        // Snapshots of text the tabs still hold, so a damaged copy is not worth keeping.
        if setAside != nil {
            LocalSQLiteStoreOpener.removeSetAsideCopies(of: databaseURL)
        }
        for statement in Self.schemaStatements {
            _ = run(statement, db: pointer) { _ in }
        }
        trim(tabId: nil, savedBefore: cutoff(before: now()), db: pointer)
    }

    // MARK: - Writes

    private func newestRow(tabId: UUID, comparedWith text: String, savedSince cutoff: Date, db: OpaquePointer) -> NewestRow? {
        let sql = """
            SELECT id, reason, idle_since, query = ? FROM tab_versions
            WHERE tab_id = ? AND saved_at >= ? ORDER BY id DESC LIMIT 1;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        Self.bind(text, to: statement, at: 1)
        Self.bind(tabId.uuidString, to: statement, at: 2)
        sqlite3_bind_double(statement, 3, cutoff.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let idleSince = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        return NewestRow(
            id: sqlite3_column_int64(statement, 0),
            reason: QueryTabVersionReason(rawValue: Int(sqlite3_column_int(statement, 1))),
            idleSince: idleSince,
            hasSameText: sqlite3_column_int(statement, 3) != 0
        )
    }

    // The coalescing window counts from the first snapshot of the run of idle pauses, so steady typing still leaves a
    // version every few minutes.
    private func replaceRow(_ id: Int64, connectionId: UUID, text: String, savedAt: Date, db: OpaquePointer) -> Bool {
        run("UPDATE tab_versions SET query = ?, saved_at = ?, connection_id = ? WHERE id = ?;", db: db) { statement in
            Self.bind(text, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, savedAt.timeIntervalSince1970)
            Self.bind(connectionId.uuidString, to: statement, at: 3)
            sqlite3_bind_int64(statement, 4, id)
        }
    }

    private func sealRow(_ id: Int64, tabId: UUID, reason: QueryTabVersionReason, db: OpaquePointer) -> Bool {
        let sealed = run("UPDATE tab_versions SET reason = ?, idle_since = NULL WHERE id = ?;", db: db) { statement in
            sqlite3_bind_int(statement, 1, Int32(reason.rawValue))
            sqlite3_bind_int64(statement, 2, id)
        }
        if sealed { announce(tabId) }
        return sealed
    }

    private func insertRow(
        tabId: UUID,
        connectionId: UUID,
        text: String,
        reason: QueryTabVersionReason,
        savedAt: Date,
        db: OpaquePointer
    ) -> Bool {
        let sql = """
            INSERT INTO tab_versions (tab_id, connection_id, query, reason, saved_at, idle_since)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        return run(sql, db: db) { statement in
            Self.bind(tabId.uuidString, to: statement, at: 1)
            Self.bind(connectionId.uuidString, to: statement, at: 2)
            Self.bind(text, to: statement, at: 3)
            sqlite3_bind_int(statement, 4, Int32(reason.rawValue))
            sqlite3_bind_double(statement, 5, savedAt.timeIntervalSince1970)
            if reason == .idle {
                sqlite3_bind_double(statement, 6, savedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 6)
            }
        }
    }

    private func trim(tabId: UUID?, savedBefore cutoff: Date, db: OpaquePointer) {
        _ = run("DELETE FROM tab_versions WHERE saved_at < ?;", db: db) { statement in
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        }
        guard let tabId else { return }
        let sql = """
            DELETE FROM tab_versions WHERE tab_id = ?1 AND id NOT IN (
                SELECT id FROM tab_versions WHERE tab_id = ?1 ORDER BY id DESC LIMIT \(Self.retainedVersionCount)
            );
            """
        _ = run(sql, db: db) { statement in
            Self.bind(tabId.uuidString, to: statement, at: 1)
        }
    }

    // MARK: - Helpers

    nonisolated private func cutoff(before date: Date) -> Date {
        date.addingTimeInterval(-TimeInterval(retentionDays) * Self.secondsPerDay)
    }

    private func run(_ sql: String, db: OpaquePointer, bind: (OpaquePointer?) -> Void) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        bind(statement)
        let result = sqlite3_step(statement)
        return result == SQLITE_DONE || result == SQLITE_ROW
    }

    fileprivate static func bind(_ text: String, to statement: OpaquePointer?, at index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, text, -1, transient)
    }
}

// Menus fill synchronously, so reads take their own connection instead of a hop to the actor.
internal final class QueryTabVersionReader: @unchecked Sendable {
    private let lock = NSLock()
    private let databaseURL: URL
    private var handle: OpaquePointer?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    func close() {
        lock.withLock {
            if let handle {
                sqlite3_close_v2(handle)
            }
            handle = nil
        }
    }

    func summaries(tabId: UUID, savedSince cutoff: Date, limit: Int) -> [QueryTabVersionSummary] {
        let sql = """
            SELECT id, reason, saved_at FROM tab_versions
            WHERE tab_id = ? AND saved_at >= ? ORDER BY id DESC LIMIT ?;
            """
        return lock.withLock {
            guard let db = openIfNeeded() else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            QueryTabVersionStorage.bind(tabId.uuidString, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, cutoff.timeIntervalSince1970)
            sqlite3_bind_int(statement, 3, Int32(clamping: limit))
            var rows: [QueryTabVersionSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let summary = Self.summary(from: statement) {
                    rows.append(summary)
                }
            }
            return rows
        }
    }

    func version(id: Int64, tabId: UUID, savedSince cutoff: Date) -> QueryTabVersion? {
        let sql = """
            SELECT id, reason, saved_at, query FROM tab_versions
            WHERE id = ? AND tab_id = ? AND saved_at >= ? LIMIT 1;
            """
        return lock.withLock {
            guard let db = openIfNeeded() else { return nil }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_int64(statement, 1, id)
            QueryTabVersionStorage.bind(tabId.uuidString, to: statement, at: 2)
            sqlite3_bind_double(statement, 3, cutoff.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let summary = Self.summary(from: statement),
                  let text = sqlite3_column_text(statement, 3) else { return nil }
            return QueryTabVersion(summary: summary, query: String(cString: text))
        }
    }

    // Opened without create: before the first write there is nothing to read.
    private func openIfNeeded() -> OpaquePointer? {
        if let handle { return handle }
        let path = databaseURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var opened: OpaquePointer?
        guard sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let opened else {
            sqlite3_close_v2(opened)
            return nil
        }
        sqlite3_busy_timeout(opened, 1_000)
        sqlite3_exec(opened, "PRAGMA query_only = 1;", nil, nil, nil)
        handle = opened
        return opened
    }

    private static func summary(from statement: OpaquePointer?) -> QueryTabVersionSummary? {
        guard let reason = QueryTabVersionReason(rawValue: Int(sqlite3_column_int(statement, 1))) else { return nil }
        return QueryTabVersionSummary(
            id: sqlite3_column_int64(statement, 0),
            reason: reason,
            savedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        )
    }
}

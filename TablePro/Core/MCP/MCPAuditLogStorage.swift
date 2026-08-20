import Combine
import CryptoKit
import Foundation
import os
import SQLite3

enum MCPAuditVerification: Equatable, Sendable {
    case intact(count: Int)
    case broken(atSequence: Int)
}

struct MCPAuditChainLink: Sendable, Equatable {
    static let genesisHash = String(repeating: "0", count: 64)

    let sequence: Int
    let previousHash: String
    let hash: String

    static func digest(entry: AuditEntry, sequence: Int, previousHash: String) -> String {
        let fields = [
            String(sequence),
            entry.id.uuidString,
            String(entry.timestamp.timeIntervalSince1970),
            entry.category.rawValue,
            entry.tokenId?.uuidString ?? "",
            entry.tokenName ?? "",
            entry.connectionId?.uuidString ?? "",
            entry.action,
            entry.outcome,
            entry.details ?? "",
            previousHash
        ]
        let joined = fields.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).hexEncoded
    }
}

actor MCPAuditLogStorage {
    static let shared = MCPAuditLogStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPAuditLogStorage")

    private static let retentionDays: Int = 90

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    private var db: OpaquePointer?
    private var dbPath: String?
    private let testDatabaseSuffix: String?
    private var nextSequence: Int = 0
    private var lastHash: String = MCPAuditChainLink.genesisHash

    init() {
        self.testDatabaseSuffix = nil
        setupDatabase()
        prune(olderThan: Self.retentionDays)
        loadChainHead()
    }

    #if DEBUG
    init(isolatedForTesting: Bool) {
        self.testDatabaseSuffix = isolatedForTesting ? "_\(UUID().uuidString)" : nil
        setupDatabase()
        prune(olderThan: Self.retentionDays)
        loadChainHead()
    }

    var databaseFilePaths: [String] {
        guard let dbPath else { return [] }
        return [dbPath, dbPath + "-wal", dbPath + "-shm"]
    }
    #endif

    deinit {
        if let db {
            sqlite3_close(db)
        }
        if Self.isRunningTests, let dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
        }
    }

    private func setupDatabase() {
        let fileManager = FileManager.default
        let directory = AppStorageEnvironment.shared.applicationSupportRoot.appendingPathComponent("TablePro")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.restrict(path: directory.path, to: 0o700)

        if Self.isRunningTests {
            Self.purgeAbandonedTestDatabases(in: directory, fileManager: fileManager)
        }

        let suffix = testDatabaseSuffix ?? ""
        let fileName = Self.isRunningTests
            ? "mcp-audit-test_\(ProcessInfo.processInfo.processIdentifier)\(suffix).db"
            : "mcp-audit.db"
        let path = directory.appendingPathComponent(fileName).path(percentEncoded: false)
        self.dbPath = path

        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            )
        }
        Self.restrict(path: path, to: 0o600)

        if sqlite3_open(path, &db) != SQLITE_OK {
            Self.logger.error("Error opening MCP audit database")
            return
        }

        execute("PRAGMA journal_mode=WAL;")
        execute("PRAGMA synchronous=NORMAL;")

        createTables()
        backfillChainIfNeeded()
        restrictDatabaseFiles()
    }

    private func restrictDatabaseFiles() {
        guard let dbPath else { return }
        Self.restrict(path: dbPath, to: 0o600)
        for suffix in ["-wal", "-shm"] {
            Self.restrict(path: dbPath + suffix, to: 0o600)
        }
    }

    private static func purgeAbandonedTestDatabases(in directory: URL, fileManager: FileManager) {
        let ownMarker = "mcp-audit-test_\(ProcessInfo.processInfo.processIdentifier)"
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("mcp-audit-test_") && !name.hasPrefix(ownMarker) {
            try? fileManager.removeItem(atPath: directory.appendingPathComponent(name).path)
        }
    }

    private static func restrict(path: String, to permissions: Int) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        } catch {
            logger.error(
                "Could not restrict permissions on the MCP audit store: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func createTables() {
        execute("""
            CREATE TABLE IF NOT EXISTS audit_entries (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                category TEXT NOT NULL,
                token_id TEXT,
                token_name TEXT,
                connection_id TEXT,
                action TEXT NOT NULL,
                outcome TEXT NOT NULL,
                details TEXT,
                sequence INTEGER,
                previous_hash TEXT,
                entry_hash TEXT
            );
            """)
        addMissingChainColumns()
        execute("CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_entries(timestamp DESC);")
        execute("CREATE INDEX IF NOT EXISTS idx_audit_token ON audit_entries(token_id, timestamp DESC);")
        execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_audit_sequence ON audit_entries(sequence);")
    }

    private func addMissingChainColumns() {
        let existing = columnNames(ofTable: "audit_entries")
        let required: [(String, String)] = [
            ("sequence", "INTEGER"),
            ("previous_hash", "TEXT"),
            ("entry_hash", "TEXT")
        ]
        for (name, type) in required where !existing.contains(name) {
            execute("ALTER TABLE audit_entries ADD COLUMN \(name) \(type);")
        }
    }

    private func columnNames(ofTable table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: raw))
            }
        }
        return names
    }

    private func backfillChainIfNeeded() {
        guard unchainedRowCount() > 0 else { return }

        let sql = """
            SELECT id, timestamp, category, token_id, token_name, connection_id, action, outcome, details
            FROM audit_entries
            ORDER BY timestamp ASC, id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }

        var pending: [AuditEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = parseEntry(statement) {
                pending.append(entry)
            }
        }
        sqlite3_finalize(statement)

        var previousHash = MCPAuditChainLink.genesisHash
        for (index, entry) in pending.enumerated() {
            let hash = MCPAuditChainLink.digest(entry: entry, sequence: index, previousHash: previousHash)
            writeChainLink(entryId: entry.id, sequence: index, previousHash: previousHash, hash: hash)
            previousHash = hash
        }
        Self.logger.info("Backfilled the audit chain over \(pending.count) existing entries")
    }

    private func unchainedRowCount() -> Int {
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM audit_entries WHERE sequence IS NULL OR entry_hash IS NULL;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func writeChainLink(entryId: UUID, sequence: Int, previousHash: String, hash: String) {
        let sql = "UPDATE audit_entries SET sequence = ?, previous_hash = ?, entry_hash = ? WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(sequence))
        sqlite3_bind_text(statement, 2, previousHash, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, hash, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, entryId.uuidString, -1, Self.SQLITE_TRANSIENT)
        sqlite3_step(statement)
    }

    private func loadChainHead() {
        let sql = "SELECT sequence, entry_hash FROM audit_entries ORDER BY sequence DESC LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            nextSequence = 0
            lastHash = MCPAuditChainLink.genesisHash
            return
        }
        nextSequence = Int(sqlite3_column_int64(statement, 0)) + 1
        lastHash = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? MCPAuditChainLink.genesisHash
    }

    private func execute(_ sql: String) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    @discardableResult
    func addEntry(_ entry: AuditEntry) -> Bool {
        let sequence = nextSequence
        let previousHash = lastHash
        let hash = MCPAuditChainLink.digest(entry: entry, sequence: sequence, previousHash: previousHash)

        let sql = """
            INSERT INTO audit_entries
                (id, timestamp, category, token_id, token_name, connection_id, action, outcome, details,
                 sequence, previous_hash, entry_hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            Self.logger.warning("Failed to prepare audit insert statement")
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, entry.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, entry.category.rawValue, -1, Self.SQLITE_TRANSIENT)
        bindOptionalText(statement, index: 4, value: entry.tokenId?.uuidString)
        bindOptionalText(statement, index: 5, value: entry.tokenName)
        bindOptionalText(statement, index: 6, value: entry.connectionId?.uuidString)
        sqlite3_bind_text(statement, 7, entry.action, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 8, entry.outcome, -1, Self.SQLITE_TRANSIENT)
        bindOptionalText(statement, index: 9, value: entry.details)
        sqlite3_bind_int64(statement, 10, Int64(sequence))
        sqlite3_bind_text(statement, 11, previousHash, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 12, hash, -1, Self.SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            Self.logger.warning("Failed to append audit entry \(entry.action, privacy: .public)")
            return false
        }

        nextSequence = sequence + 1
        lastHash = hash
        Task { @MainActor in
            AppEvents.shared.mcpAuditLogChanged.send(())
        }
        return true
    }

    private func bindOptionalText(_ statement: OpaquePointer?, index: Int32, value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.SQLITE_TRANSIENT)
    }

    func query(
        category: AuditCategory? = nil,
        tokenId: UUID? = nil,
        since: Date? = nil,
        limit: Int = 500
    ) -> [AuditEntry] {
        var conditions: [String] = []
        if category != nil { conditions.append("category = ?") }
        if tokenId != nil { conditions.append("token_id = ?") }
        if since != nil { conditions.append("timestamp >= ?") }

        var sql = """
            SELECT id, timestamp, category, token_id, token_name, connection_id, action, outcome, details
            FROM audit_entries
            """
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY timestamp DESC LIMIT ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            Self.logger.warning("Failed to prepare audit query statement")
            return []
        }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        if let category {
            sqlite3_bind_text(statement, bindIndex, category.rawValue, -1, Self.SQLITE_TRANSIENT)
            bindIndex += 1
        }
        if let tokenId {
            sqlite3_bind_text(statement, bindIndex, tokenId.uuidString, -1, Self.SQLITE_TRANSIENT)
            bindIndex += 1
        }
        if let since {
            sqlite3_bind_double(statement, bindIndex, since.timeIntervalSince1970)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))

        var entries: [AuditEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = parseEntry(statement) {
                entries.append(entry)
            }
        }
        return entries
    }

    func verify() -> MCPAuditVerification {
        let sql = """
            SELECT id, timestamp, category, token_id, token_name, connection_id, action, outcome, details,
                   sequence, previous_hash, entry_hash
            FROM audit_entries
            ORDER BY sequence ASC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            Self.logger.warning("Failed to prepare audit verification statement")
            return .broken(atSequence: 0)
        }
        defer { sqlite3_finalize(statement) }

        var expectedPrevious: String?
        var expectedSequence: Int?
        var count = 0

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let entry = parseEntry(statement) else {
                return .broken(atSequence: Int(sqlite3_column_int64(statement, 9)))
            }
            let sequence = Int(sqlite3_column_int64(statement, 9))
            let previousHash = sqlite3_column_text(statement, 10).map { String(cString: $0) } ?? ""
            let storedHash = sqlite3_column_text(statement, 11).map { String(cString: $0) } ?? ""

            let recomputed = MCPAuditChainLink.digest(
                entry: entry,
                sequence: sequence,
                previousHash: previousHash
            )
            if storedHash != recomputed {
                return .broken(atSequence: sequence)
            }
            if let expectedPrevious, previousHash != expectedPrevious {
                return .broken(atSequence: sequence)
            }
            if let expectedSequence, sequence != expectedSequence {
                return .broken(atSequence: sequence)
            }
            expectedPrevious = storedHash
            expectedSequence = sequence + 1
            count += 1
        }
        return .intact(count: count)
    }

    func count() -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM audit_entries;", -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }

    @discardableResult
    func prune(olderThan days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let sql = "DELETE FROM audit_entries WHERE timestamp < ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    @discardableResult
    func deleteAll() -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM audit_entries;", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        nextSequence = 0
        lastHash = MCPAuditChainLink.genesisHash
        return true
    }

    private func parseEntry(_ statement: OpaquePointer?) -> AuditEntry? {
        guard let statement,
              let idCString = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: idCString)),
              let categoryCString = sqlite3_column_text(statement, 2),
              let category = AuditCategory(rawValue: String(cString: categoryCString)),
              let actionCString = sqlite3_column_text(statement, 6),
              let outcomeCString = sqlite3_column_text(statement, 7)
        else {
            return nil
        }

        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        let tokenId = sqlite3_column_text(statement, 3).flatMap { UUID(uuidString: String(cString: $0)) }
        let tokenName = sqlite3_column_text(statement, 4).map { String(cString: $0) }
        let connectionId = sqlite3_column_text(statement, 5).flatMap { UUID(uuidString: String(cString: $0)) }
        let action = String(cString: actionCString)
        let outcome = String(cString: outcomeCString)
        let details = sqlite3_column_text(statement, 8).map { String(cString: $0) }

        return AuditEntry(
            id: id,
            timestamp: timestamp,
            category: category,
            tokenId: tokenId,
            tokenName: tokenName,
            connectionId: connectionId,
            action: action,
            outcome: outcome,
            details: details
        )
    }
}

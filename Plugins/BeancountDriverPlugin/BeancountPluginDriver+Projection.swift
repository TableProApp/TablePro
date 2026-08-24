//
//  BeancountPluginDriver+Projection.swift
//  BeancountDriverPlugin
//

import Foundation
import SQLite3

private struct BeancountSourcePosition {
    let file: String?
    let line: Int?
    let formatted: String?
}

private final class BeancountProjectionWriter {
    private let db: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    init(db: OpaquePointer) {
        self.db = db
    }

    deinit {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
    }

    func insert(sql: String, values: [String?]) throws {
        let statement = try preparedStatement(sql)
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)

        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            if let value {
                sqlite3_bind_text(statement, position, value, -1, projectionSQLiteTransient)
            } else {
                sqlite3_bind_null(statement, position)
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw BeancountDriverError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func preparedStatement(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] {
            return cached
        }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw BeancountDriverError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        statements[sql] = prepared
        return prepared
    }
}

struct BeancountProjectionRows: @unchecked Sendable {
    var transactions: [[String: Any]] = []
    var postings: [[String: Any]] = []
    var accounts: [[String: Any]] = []
    var prices: [[String: Any]] = []
    var balances: [[String: Any]] = []
    var balanceAssertions: [[String: Any]] = []
    var commodities: [[String: Any]] = []
    var documents: [[String: Any]] = []
    var notes: [[String: Any]] = []
    var events: [[String: Any]] = []
    var pads: [[String: Any]] = []
    var closes: [[String: Any]] = []
    var diagnostics: [[String: Any]] = []
}

struct BeancountPadProjection: @unchecked Sendable {
    var rows: [[String: Any]] = []
    var diagnostics: [[String: Any]] = []
}

extension BeancountPluginDriver {
    static func loadProjection(rows: BeancountProjectionRows, sourceFiles: [URL]) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let openResult = sqlite3_open(":memory:", &handle)
        guard openResult == SQLITE_OK, let handle else {
            if let handle {
                sqlite3_close(handle)
            }
            throw BeancountDriverError.connectionFailed(
                String(localized: "Could not initialize SQL projection")
            )
        }

        do {
            try createSchema(handle)
            let writer = BeancountProjectionWriter(db: handle)
            let transactionIDs = try loadTransactions(rows.transactions, into: writer)
            try loadPostings(rows.postings, transactionIDs: transactionIDs, into: writer)
            try loadAccounts(rows.accounts, into: writer)
            try loadPrices(rows.prices, into: writer)
            try loadBalances(rows.balances, into: writer)
            try loadBalanceAssertions(rows.balanceAssertions, into: writer)
            try loadCommodities(rows.commodities, into: writer)
            try loadDocuments(rows.documents, into: writer)
            try loadNotes(rows.notes, into: writer)
            try loadEvents(rows.events, into: writer)
            try loadPads(rows.pads, into: writer)
            try loadCloses(rows.closes, into: writer)
            try loadDiagnostics(rows.diagnostics, into: writer)
            try loadSourceFiles(sourceFiles, into: writer)
            try exec(handle, "PRAGMA query_only = ON")
        } catch {
            sqlite3_close(handle)
            throw error
        }

        return handle
    }

    private static func createSchema(_ db: OpaquePointer) throws {
        try exec(db, """
            CREATE TABLE transactions (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                flag TEXT NOT NULL,
                payee TEXT,
                narration TEXT,
                source_file TEXT,
                line INTEGER,
                source_location TEXT
            );
            CREATE TABLE postings (
                id INTEGER PRIMARY KEY,
                transaction_id INTEGER NOT NULL,
                date DATE NOT NULL,
                account TEXT NOT NULL,
                amount TEXT,
                commodity TEXT,
                flag TEXT,
                cost_number TEXT,
                cost_currency TEXT,
                cost_date DATE,
                cost_label TEXT,
                price_number TEXT,
                price_currency TEXT,
                source_file TEXT,
                line INTEGER,
                source_location TEXT
            );
            CREATE TABLE accounts (
                name TEXT PRIMARY KEY,
                open_date DATE,
                currencies TEXT
            );
            CREATE TABLE prices (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                commodity TEXT NOT NULL,
                amount TEXT NOT NULL,
                currency TEXT NOT NULL
            );
            CREATE TABLE balances (
                id INTEGER PRIMARY KEY,
                account TEXT NOT NULL,
                amount TEXT NOT NULL,
                commodity TEXT NOT NULL
            );
            CREATE TABLE balance_assertions (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                account TEXT NOT NULL,
                amount TEXT NOT NULL,
                commodity TEXT NOT NULL
            );
            CREATE TABLE commodities (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                commodity TEXT NOT NULL
            );
            CREATE TABLE documents (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                account TEXT NOT NULL,
                path TEXT NOT NULL,
                tags TEXT,
                links TEXT
            );
            CREATE TABLE notes (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                account TEXT NOT NULL,
                comment TEXT
            );
            CREATE TABLE events (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                type TEXT NOT NULL,
                description TEXT
            );
            CREATE TABLE pads (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                account TEXT NOT NULL,
                source_account TEXT NOT NULL,
                source_file TEXT,
                line INTEGER,
                source_location TEXT
            );
            CREATE TABLE closes (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                account TEXT NOT NULL
            );
            CREATE TABLE transaction_metadata (
                id INTEGER PRIMARY KEY,
                transaction_id INTEGER NOT NULL,
                key TEXT NOT NULL,
                value TEXT
            );
            CREATE TABLE posting_metadata (
                id INTEGER PRIMARY KEY,
                posting_id INTEGER NOT NULL,
                key TEXT NOT NULL,
                value TEXT
            );
            CREATE TABLE transaction_tags (
                id INTEGER PRIMARY KEY,
                transaction_id INTEGER NOT NULL,
                tag TEXT NOT NULL
            );
            CREATE TABLE transaction_links (
                id INTEGER PRIMARY KEY,
                transaction_id INTEGER NOT NULL,
                link TEXT NOT NULL
            );
            CREATE TABLE diagnostics (
                id INTEGER PRIMARY KEY,
                source_file TEXT,
                line INTEGER,
                source_location TEXT,
                column_number INTEGER,
                end_line INTEGER,
                end_column INTEGER,
                severity TEXT,
                phase TEXT,
                code TEXT,
                message TEXT
            );
            CREATE TABLE source_files (
                path TEXT PRIMARY KEY
            );
            """)
    }

    private static func loadTransactions(
        _ rows: [[String: Any]],
        into writer: BeancountProjectionWriter
    ) throws -> Set<Int> {
        var transactionIDs: Set<Int> = []
        var metadataID = 0
        var tagID = 0
        var linkID = 0

        for row in rows {
            guard let transactionID = intValue(row["id"]),
                  let date = stringValue(row["date"]),
                  transactionIDs.insert(transactionID).inserted else {
                continue
            }

            let position = sourcePosition(
                file: row["filename"],
                line: row["lineno"],
                formatted: row["location"]
            )
            try writer.insert(sql: """
                INSERT INTO transactions (id, date, flag, payee, narration, source_file, line, source_location)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, values: [
                    String(transactionID),
                    date,
                    stringValue(row["flag"]) ?? "*",
                    stringValue(row["payee"]),
                    stringValue(row["narration"]),
                    position?.file,
                    position?.line.map(String.init),
                    position?.formatted
                ])

            for entry in metadataPairs(row["_entry_meta"]) {
                metadataID += 1
                try writer.insert(sql: """
                    INSERT INTO transaction_metadata (id, transaction_id, key, value)
                    VALUES (?, ?, ?, ?)
                    """, values: [String(metadataID), String(transactionID), entry.key, entry.value])
            }

            for tag in stringList(row["tags"]) {
                tagID += 1
                try writer.insert(sql: """
                    INSERT INTO transaction_tags (id, transaction_id, tag) VALUES (?, ?, ?)
                    """, values: [String(tagID), String(transactionID), tag])
            }

            for link in stringList(row["links"]) {
                linkID += 1
                try writer.insert(sql: """
                    INSERT INTO transaction_links (id, transaction_id, link) VALUES (?, ?, ?)
                    """, values: [String(linkID), String(transactionID), link])
            }
        }

        return transactionIDs
    }

    private static func loadPostings(
        _ rows: [[String: Any]],
        transactionIDs: Set<Int>,
        into writer: BeancountProjectionWriter
    ) throws {
        var postingID = 0
        var metadataID = 0

        for row in rows {
            guard let transactionID = intValue(row["transaction_id"]),
                  let date = stringValue(row["date"]),
                  let account = stringValue(row["account"]) else {
                continue
            }
            guard transactionIDs.contains(transactionID) else {
                throw BeancountDriverError.queryFailed(
                    String(
                        format: String(localized: "Beancount posting references missing transaction ID %@"),
                        String(transactionID)
                    )
                )
            }

            postingID += 1
            let position = sourcePosition(
                file: row["filename"],
                line: row["lineno"],
                formatted: row["location"]
            )
            let price = amountFields(row["price"])
            try writer.insert(sql: """
                INSERT INTO postings
                (id, transaction_id, date, account, amount, commodity, flag,
                 cost_number, cost_currency, cost_date, cost_label, price_number, price_currency,
                 source_file, line, source_location)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values: [
                    String(postingID),
                    String(transactionID),
                    date,
                    account,
                    stringValue(row["number"]),
                    stringValue(row["currency"]),
                    stringValue(row["posting_flag"]),
                    stringValue(row["cost_number"]),
                    stringValue(row["cost_currency"]),
                    stringValue(row["cost_date"]),
                    stringValue(row["cost_label"]),
                    price.number,
                    price.currency,
                    position?.file,
                    position?.line.map(String.init),
                    position?.formatted
                ])

            for entry in metadataPairs(row["_posting_meta"]) {
                metadataID += 1
                try writer.insert(sql: """
                    INSERT INTO posting_metadata (id, posting_id, key, value)
                    VALUES (?, ?, ?, ?)
                    """, values: [String(metadataID), String(postingID), entry.key, entry.value])
            }
        }
    }

    private static func loadCommodities(_ rows: [[String: Any]], into writer: BeancountProjectionWriter) throws {
        var commodityId = 0
        for row in rows {
            guard let date = stringValue(row["date"]),
                  let commodity = stringValue(row["name"]) ?? stringValue(row["commodity"]) else {
                continue
            }
            commodityId += 1
            try writer.insert(sql: """
                INSERT INTO commodities (id, date, commodity) VALUES (?, ?, ?)
                """, values: [String(commodityId), date, commodity])
        }
    }

    private static func loadDocuments(_ rows: [[String: Any]], into writer: BeancountProjectionWriter) throws {
        var documentId = 0
        for row in rows {
            guard let date = stringValue(row["date"]),
                  let account = stringValue(row["account"]),
                  let path = stringValue(row["filename"]) ?? stringValue(row["path"]) else {
                continue
            }
            documentId += 1
            try writer.insert(sql: """
                INSERT INTO documents (id, date, account, path, tags, links) VALUES (?, ?, ?, ?, ?, ?)
                """, values: [
                    String(documentId),
                    date,
                    account,
                    path,
                    joinedList(row["tags"]),
                    joinedList(row["links"])
                ])
        }
    }

    private static func loadNotes(_ rows: [[String: Any]], into writer: BeancountProjectionWriter) throws {
        var noteId = 0
        for row in rows {
            guard let date = stringValue(row["date"]),
                  let account = stringValue(row["account"]) else { continue }
            noteId += 1
            try writer.insert(sql: """
                INSERT INTO notes (id, date, account, comment) VALUES (?, ?, ?, ?)
                """, values: [String(noteId), date, account, stringValue(row["comment"])])
        }
    }

    private static func loadEvents(_ rows: [[String: Any]], into writer: BeancountProjectionWriter) throws {
        var eventId = 0
        for row in rows {
            guard let date = stringValue(row["date"]),
                  let type = stringValue(row["type"]) else { continue }
            eventId += 1
            try writer.insert(sql: """
                INSERT INTO events (id, date, type, description) VALUES (?, ?, ?, ?)
                """, values: [String(eventId), date, type, stringValue(row["description"])])
        }
    }

    private static func loadPads(_ rows: [[String: Any]], into writer: BeancountProjectionWriter) throws {
        var padId = 0
        for row in rows {
            guard let date = stringValue(row["date"]),
                  let account = stringValue(row["account"]),
                  let sourceAccount = stringValue(row["source_account"]) else {
                continue
            }
            let position = sourcePosition(file: row["filename"], line: row["lineno"], formatted: row["location"])
            padId += 1
            try writer.insert(sql: """
                INSERT INTO pads (id, date, account, source_account, source_file, line, source_location)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, values: [
                    String(padId),
                    date,
                    account,
                    sourceAccount,
                    position?.file,
                    position?.line.map(String.init),
                    position?.formatted
                ])
        }
    }

    private static func loadCloses(_ rows: [[String: Any]], into writer: BeancountProjectionWriter) throws {
        var closeId = 0
        for row in rows {
            guard let account = stringValue(row["account"]),
                  let date = stringValue(row["close"]) ?? stringValue(row["date"]) else { continue }
            closeId += 1
            try writer.insert(sql: """
                INSERT INTO closes (id, date, account) VALUES (?, ?, ?)
                """, values: [String(closeId), date, account])
        }
    }

    private static func loadDiagnostics(_ rows: [[String: Any]], into writer: BeancountProjectionWriter) throws {
        var diagnosticId = 0
        for row in rows {
            diagnosticId += 1
            let position = sourcePosition(file: row["file"], line: row["line"], formatted: nil)
            try writer.insert(sql: """
                INSERT INTO diagnostics
                (id, source_file, line, source_location, column_number, end_line, end_column,
                 severity, phase, code, message)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values: [
                    String(diagnosticId),
                    position?.file,
                    position?.line.map(String.init),
                    position?.formatted,
                    intValue(row["column"]).map(String.init),
                    intValue(row["end_line"]).map(String.init),
                    intValue(row["end_column"]).map(String.init),
                    stringValue(row["severity"]),
                    stringValue(row["phase"]),
                    stringValue(row["code"]),
                    stringValue(row["message"])
                ])
        }
    }

    private static func loadAccounts(_ rows: [[String: Any]], into writer: BeancountProjectionWriter) throws {
        for row in rows {
            guard let name = stringValue(row["account"]) else { continue }
            try writer.insert(sql: """
                INSERT OR REPLACE INTO accounts (name, open_date, currencies)
                VALUES (?, ?, ?)
                """, values: [
                    name,
                    stringValue(row["open"]),
                    joinedList(row["currencies"])
                ])
        }
    }

    private static func loadPrices(_ rows: [[String: Any]], into writer: BeancountProjectionWriter) throws {
        var priceId = 0
        for row in rows {
            guard let commodity = stringValue(row["currency"]),
                  let date = stringValue(row["date"]) else {
                continue
            }
            let amount = amountFields(row["amount"])
            guard let number = amount.number, let currency = amount.currency else { continue }
            priceId += 1
            try writer.insert(sql: """
                INSERT INTO prices (id, date, commodity, amount, currency)
                VALUES (?, ?, ?, ?, ?)
                """, values: [String(priceId), date, commodity, number, currency])
        }
    }

    private static func loadBalances(_ rows: [[String: Any]], into writer: BeancountProjectionWriter) throws {
        var balanceId = 0
        for row in rows {
            guard let account = stringValue(row["account"]) else { continue }
            for position in inventoryPositions(row["balance"]) {
                balanceId += 1
                try writer.insert(sql: """
                    INSERT INTO balances (id, account, amount, commodity)
                    VALUES (?, ?, ?, ?)
                    """, values: [String(balanceId), account, position.number, position.currency])
            }
        }
    }

    private static func loadBalanceAssertions(_ rows: [[String: Any]], into writer: BeancountProjectionWriter) throws {
        var balanceId = 0
        for row in rows {
            guard let account = stringValue(row["account"]),
                  let date = stringValue(row["date"]) else { continue }
            let amount = amountFields(row["amount"])
            guard let number = amount.number, let commodity = amount.currency else { continue }
            balanceId += 1
            try writer.insert(sql: """
                INSERT INTO balance_assertions (id, date, account, amount, commodity)
                VALUES (?, ?, ?, ?, ?)
                """, values: [String(balanceId), date, account, number, commodity])
        }
    }

    private static func loadSourceFiles(_ files: [URL], into writer: BeancountProjectionWriter) throws {
        for file in files {
            try writer.insert(sql: "INSERT OR IGNORE INTO source_files (path) VALUES (?)", values: [file.path])
        }
    }

    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func amountFields(_ value: Any?) -> (number: String?, currency: String?) {
        guard let dictionary = value as? [String: Any] else { return (nil, nil) }
        return (stringValue(dictionary["number"]), stringValue(dictionary["currency"]))
    }

    private static func inventoryPositions(_ value: Any?) -> [(number: String, currency: String)] {
        guard let dictionary = value as? [String: Any],
              let positions = dictionary["positions"] as? [[String: Any]] else {
            return []
        }
        return positions.compactMap { position in
            guard let number = stringValue(position["number"]),
                  let currency = stringValue(position["currency"]) else {
                return nil
            }
            return (number: number, currency: currency)
        }
    }

    private static func joinedList(_ value: Any?) -> String? {
        guard let array = value as? [Any] else { return stringValue(value) }
        let items = array.compactMap { $0 as? String }
        return items.isEmpty ? nil : items.joined(separator: " ")
    }

    private static func stringList(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else {
            guard let joined = stringValue(value) else { return [] }
            return joined
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map(String.init)
        }
        return array.compactMap { $0 as? String }
    }

    private static func metadataPairs(_ value: Any?) -> [(key: String, value: String?)] {
        guard let dictionary = value as? [String: Any] else { return [] }
        return dictionary.keys.sorted().map { key in
            guard let raw = dictionary[key], !(raw is NSNull) else {
                return (key: key, value: nil)
            }
            return (key: key, value: metadataValue(raw))
        }
    }

    private static func metadataValue(_ raw: Any) -> String? {
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "TRUE" : "FALSE"
        }
        return stringValue(raw) ?? BeancountPluginDriver.rustledgerCellValue(raw)
    }

    private static func sourcePosition(file: Any?, line: Any?, formatted: Any?) -> BeancountSourcePosition? {
        let path = stringValue(file).flatMap { $0.isEmpty ? nil : $0 }
        let lineNumber = intValue(line).flatMap { $0 > 0 ? $0 : nil }
        guard path != nil || lineNumber != nil else { return nil }
        let rendered = stringValue(formatted).flatMap { $0.isEmpty ? nil : $0 }
            ?? path.flatMap { path in lineNumber.map { "\(path):\($0)" } }
        return BeancountSourcePosition(file: path, line: lineNumber, formatted: rendered)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if error != nil {
                sqlite3_free(error)
            }
            throw BeancountDriverError.queryFailed(message)
        }
    }
}

private let projectionSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

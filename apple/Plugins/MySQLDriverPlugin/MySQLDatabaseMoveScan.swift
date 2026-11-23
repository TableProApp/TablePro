//
//  MySQLDatabaseMoveScan.swift
//  MySQLDriverPlugin
//
//  What one statement can do to the database a session is on, read in a single forward pass.
//

import Foundation

nonisolated internal struct MySQLDatabaseMove: Equatable, Sendable {
    var changesDatabase = false
    var runsOpaqueCode = false
    var staysOnDatabase = false
}

// A server skips a version-gated comment or runs it, so every word that can open the statement under either reading
// counts. It closes a skipped comment at the first `*/`, strings included, which is why the walk ignores strings there.
nonisolated internal enum MySQLDatabaseMoveScan {
    static func move(of sql: String) -> MySQLDatabaseMove {
        var text = sql
        return text.withUTF8 { walk($0) }
    }

    // None of these can leave the database: routines refuse `USE`, and a stored function or trigger refuses dynamic SQL.
    // A `RELEASE` on COMMIT or ROLLBACK ends the session, and the next one starts without a proof.
    private static let provenHeads: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "REPLACE", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "WITH", "VALUES",
        "TABLE", "DO", "COMMIT", "ROLLBACK",
    ]

    // MariaDB runs these blocks outside a routine, and a block can hold `EXECUTE IMMEDIATE`.
    private static let opaqueHeads: Set<String> = ["CALL", "EXECUTE", "IF", "WHILE", "LOOP", "REPEAT", "CASE", "FOR"]

    private static let longestKeyword = 8

    private static func walk(_ bytes: UnsafeBufferPointer<UInt8>) -> MySQLDatabaseMove {
        var move = MySQLDatabaseMove()
        var index = 0
        var depth = 0
        var expectsHead = true
        var sawExecutableComment = false

        while index < bytes.count {
            let byte = bytes[index]
            if isSpace(byte) {
                index += 1
            } else if depth > 0, startsPlainComment(bytes, at: index) {
                // A comment inside one: MySQL closes `/*M!` at the first `*/`, MariaDB lets one level nest.
                move.runsOpaqueCode = true
                return move
            } else if let marker = executableMarkerLength(in: bytes, at: index) {
                depth += 1
                sawExecutableComment = true
                index += marker
            } else if startsPlainComment(bytes, at: index) {
                index = endOfPlainComment(in: bytes, from: index + 2)
            } else if depth > 0, byte == asciiStar, byteAt(bytes, index + 1) == asciiSlash {
                depth -= 1
                expectsHead = true
                index += 2
            } else if !expectsHead {
                index += 1
            } else if startsLineComment(bytes, at: index) {
                // The server's two readings disagree on where this comment's text ends.
                guard depth == 0 else {
                    move.runsOpaqueCode = true
                    return move
                }
                index = endOfLine(in: bytes, from: index)
            } else if isWordByte(byte) {
                let end = endOfWord(in: bytes, from: index)
                let head = keyword(in: bytes, from: index, to: end)
                note(head: head, in: bytes, after: end, on: &move)
                guard depth > 0 else {
                    move.staysOnDatabase = head.map(provenHeads.contains) == true
                        && !sawExecutableComment
                        && isSingleStatementWithoutMarkers(bytes, from: end)
                    return move
                }
                expectsHead = false
                index = end
            } else {
                guard depth > 0 else { return move }
                expectsHead = false
                index += 1
            }
        }
        return move
    }

    private static func note(
        head: String?,
        in bytes: UnsafeBufferPointer<UInt8>,
        after end: Int,
        on move: inout MySQLDatabaseMove
    ) {
        guard let head else { return }
        if head == "USE" {
            move.changesDatabase = true
        } else if opaqueHeads.contains(head) || (head == "BEGIN" && nextWordIsNot(in: bytes, from: end)) {
            move.runsOpaqueCode = true
        }
    }

    // `BEGIN NOT ATOMIC` opens a block, where a bare `BEGIN` opens a transaction.
    private static func nextWordIsNot(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Bool {
        var index = start
        while index < bytes.count {
            if isSpace(bytes[index]) {
                index += 1
            } else if startsPlainComment(bytes, at: index) {
                index = endOfPlainComment(in: bytes, from: index + 2)
            } else {
                break
            }
        }
        return keyword(in: bytes, from: index, to: endOfWord(in: bytes, from: index)) == "NOT"
    }

    // A `;` in a literal reads as a second statement here, which only costs the `USE` this scan would have saved.
    private static func isSingleStatementWithoutMarkers(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Bool {
        var sawSemicolon = false
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if executableMarkerLength(in: bytes, at: index) != nil { return false }
            if sawSemicolon, !isSpace(byte) { return false }
            if byte == asciiSemicolon { sawSemicolon = true }
            index += 1
        }
        return true
    }

    private static let asciiSlash = UInt8(ascii: "/")
    private static let asciiStar = UInt8(ascii: "*")
    private static let asciiBang = UInt8(ascii: "!")
    private static let asciiSemicolon = UInt8(ascii: ";")
    private static let asciiNewline = UInt8(ascii: "\n")

    private static func byteAt(_ bytes: UnsafeBufferPointer<UInt8>, _ index: Int) -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        isDigit(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$") || byte >= 0x80
    }

    private static func startsPlainComment(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        bytes[index] == asciiSlash && byteAt(bytes, index + 1) == asciiStar
    }

    // `/*!` on both servers and `/*M!` on MariaDB, with the version digits that follow.
    private static func executableMarkerLength(in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int? {
        guard startsPlainComment(bytes, at: index) else { return nil }
        var end = index + 2
        if byteAt(bytes, end) == UInt8(ascii: "M") { end += 1 }
        guard byteAt(bytes, end) == asciiBang else { return nil }
        end += 1
        while let byte = byteAt(bytes, end), isDigit(byte) { end += 1 }
        return end - index
    }

    private static func endOfPlainComment(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == asciiStar, bytes[index + 1] == asciiSlash { return index + 2 }
            index += 1
        }
        return bytes.count
    }

    // `--` opens a comment only before whitespace or a control character.
    private static func startsLineComment(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        if bytes[index] == UInt8(ascii: "#") { return true }
        guard bytes[index] == UInt8(ascii: "-"), byteAt(bytes, index + 1) == UInt8(ascii: "-") else { return false }
        guard let next = byteAt(bytes, index + 2) else { return true }
        return next <= 0x20 || next == 0x7F
    }

    private static func endOfLine(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] != asciiNewline { index += 1 }
        return index
    }

    private static func endOfWord(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        while index < bytes.count, isWordByte(bytes[index]) { index += 1 }
        return index
    }

    // ASCII only: `uppercased()` turns the long s in `uſe` into an S, and the server reads that word as a name.
    private static func keyword(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> String? {
        guard end > start, end - start <= longestKeyword else { return nil }
        let word = bytes[start..<end]
        guard word.allSatisfy({ $0 < 0x80 }) else { return nil }
        return String(decoding: word.map { (0x61...0x7A).contains($0) ? $0 - 0x20 : $0 }, as: UTF8.self)
    }
}

// Advanced on the connection's queue, so it follows the order statements reach the server.
nonisolated internal struct MySQLSessionDatabaseProof: Equatable, Sendable {
    private(set) var database: String?

    // The driver's own begin carries a version comment the scan cannot prove, and it cannot leave the database.
    mutating func observe(_ sql: String, flavor: MySQLServerFlavor) {
        guard database != nil, !flavor.isOwnTransactionStart(sql),
              !MySQLDatabaseMoveScan.move(of: sql).staysOnDatabase else { return }
        database = nil
    }

    mutating func noteEntered(_ database: String) {
        self.database = database
    }

    // By bytes: `==` on strings takes a composed and a decomposed accent as one name, and the server does not.
    func proves(_ database: String) -> Bool {
        guard let entered = self.database, !database.isEmpty else { return false }
        return entered.utf8.elementsEqual(database.utf8)
    }
}

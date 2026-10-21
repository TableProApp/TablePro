//
//  MySQLTemporaryTableNames.swift
//  MySQLDriverPlugin
//

import Foundation

// MySQL 8.4.11 lists a session's temporary tables nowhere an ordinary user can read (`INNODB_TEMP_TABLE_INFO` needs
// PROCESS), so the names come from the statement text. Only the table part is kept: `SHOW CREATE TABLE name` on the
// session resolves it in the browsed database and answers `CREATE TEMPORARY TABLE` for one.
enum MySQLTemporaryTableNames {
    static func created(by statement: String) -> String? {
        var reader = Reader(statement)
        guard reader.accept("CREATE") else { return nil }
        if reader.accept("OR") {
            guard reader.accept("REPLACE") else { return nil }
        }
        guard reader.accept("TEMPORARY"), reader.accept("TABLE") else { return nil }
        if reader.accept("IF") {
            guard reader.accept("NOT"), reader.accept("EXISTS") else { return nil }
        }
        return reader.tableName()
    }

    static func declaresTemporaryTable(_ createStatement: String) -> Bool {
        var reader = Reader(createStatement)
        return reader.accept("CREATE") && reader.accept("TEMPORARY")
    }

    static func renames(in statement: String) -> [(from: String, to: String)] {
        var reader = Reader(statement)
        if reader.accept("RENAME") {
            guard reader.accept("TABLE") || reader.accept("TABLES") else { return [] }
            var pairs: [(from: String, to: String)] = []
            repeat {
                guard let from = reader.tableName(), reader.accept("TO"), let to = reader.tableName() else { return pairs }
                pairs.append((from, to))
            } while reader.acceptComma()
            return pairs
        }
        guard reader.accept("ALTER") else { return [] }
        _ = reader.accept("ONLINE")
        _ = reader.accept("IGNORE")
        guard reader.accept("TABLE"), let from = reader.tableName() else { return [] }
        while let token = reader.next() {
            guard case .word(let word) = token, word.uppercased() == "RENAME" else { continue }
            if reader.accept("COLUMN") || reader.accept("INDEX") || reader.accept("KEY") { continue }
            _ = reader.accept("TO") || reader.accept("AS")
            guard let to = reader.tableName() else { return [] }
            return [(from, to)]
        }
        return []
    }
}

private enum NameToken: Equatable {
    case word(String)
    case quoted(String)
    case dot
    case comma
    case other
}

// A string literal is one `other` token, so a keyword inside one is never read.
private struct Reader {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var executableCommentDepth = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    mutating func accept(_ keyword: String) -> Bool {
        let start = index
        guard case .word(let word) = next(), word.uppercased() == keyword else {
            index = start
            return false
        }
        return true
    }

    mutating func acceptComma() -> Bool {
        let start = index
        guard next() == .comma else {
            index = start
            return false
        }
        return true
    }

    mutating func tableName() -> String? {
        guard var name = identifier() else { return nil }
        let start = index
        if next() == .dot {
            guard let table = identifier() else { return nil }
            name = table
        } else {
            index = start
        }
        return name
    }

    private mutating func identifier() -> String? {
        switch next() {
        case .word(let word): return word
        case .quoted(let name): return name.isEmpty ? nil : name
        case .dot, .comma, .other, nil: return nil
        }
    }

    mutating func next() -> NameToken? {
        skipBlanks()
        guard index < scalars.count else { return nil }
        let scalar = scalars[index]
        switch scalar {
        case ".":
            index += 1
            return .dot
        case ",":
            index += 1
            return .comma
        case "`", "\"":
            return .quoted(quoted(closingWith: scalar))
        case "'":
            _ = quoted(closingWith: scalar)
            return .other
        default:
            guard Self.isWordScalar(scalar) else {
                index += 1
                return .other
            }
            var word = String.UnicodeScalarView()
            while index < scalars.count, Self.isWordScalar(scalars[index]) {
                word.append(scalars[index])
                index += 1
            }
            return .word(String(word))
        }
    }

    private mutating func quoted(closingWith quote: Unicode.Scalar) -> String {
        index += 1
        var body = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            guard scalar == quote else {
                body.append(scalar)
                continue
            }
            guard index < scalars.count, scalars[index] == quote else { break }
            body.append(quote)
            index += 1
        }
        return String(body)
    }

    private mutating func skipBlanks() {
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.properties.isWhitespace {
                index += 1
            } else if scalar == "#" || startsLineComment() {
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
            } else if scalar == "/", peek(1) == "*", let opener = executableCommentOpener() {
                // MySQL runs the body of `/*!NNNNN ... */`, so `CREATE /*!32312 TEMPORARY */ TABLE` creates one.
                index += opener
                while index < scalars.count, scalars[index].properties.numericType != nil { index += 1 }
                executableCommentDepth += 1
            } else if scalar == "*", peek(1) == "/", executableCommentDepth > 0 {
                index += 2
                executableCommentDepth -= 1
            } else if scalar == "/", peek(1) == "*" {
                index += 2
                while index < scalars.count, !(scalars[index] == "*" && peek(1) == "/") { index += 1 }
                index = min(index + 2, scalars.count)
            } else {
                return
            }
        }
    }

    private func executableCommentOpener() -> Int? {
        if peek(2) == "!" { return 3 }
        if peek(2) == "M", peek(3) == "!" { return 4 }
        return nil
    }

    // `--` opens a comment only when a space or a control character follows it.
    private func startsLineComment() -> Bool {
        guard scalars[index] == "-", peek(1) == "-" else { return false }
        guard let after = peek(2) else { return true }
        return after.properties.isWhitespace || after.value < 0x20
    }

    private func peek(_ offset: Int) -> Unicode.Scalar? {
        let position = index + offset
        return position < scalars.count ? scalars[position] : nil
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar == "$" || scalar.value >= 0x80 || CharacterSet.alphanumerics.contains(scalar)
    }
}

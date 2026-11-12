import Foundation

// What a statement does to the session's transaction, read from its first keyword. Anything not known to be a read or
// a transaction statement counts as a change, so a misread keeps a transaction reported open rather than hidden.
enum TeradataStatementKind: Equatable {
    case read
    case change
    case begin
    case end
    case commit
    case rollback

    static func kinds(in request: String) -> [TeradataStatementKind] {
        TeradataRequestTokens.statements(in: request).map { kind(of: $0[...]) }
    }

    private static let readKeywords: Set<String> = ["SELECT", "SEL", "HELP", "SHOW", "EXPLAIN"]
    private static let writeKeywords: Set<String> = ["INSERT", "INS", "UPDATE", "UPD", "DELETE", "DEL", "MERGE"]
    private static let lockTypes: Set<String> = ["ACCESS", "READ", "WRITE", "EXCLUSIVE", "SHARE", "CHECKSUM", "LOAD"]
    private static let lockTypeModifiers: Set<String> = ["MODE", "NOWAIT", "OVERRIDE"]

    private static func kind(of tokens: ArraySlice<TeradataRequestTokens.Token>) -> TeradataStatementKind {
        let statement = tokens.drop { $0 == .symbol(UInt8(ascii: "(")) }
        guard case .word(let keyword)? = statement.first else { return .change }
        let rest = statement.dropFirst()
        // `SELECT AND CONSUME` removes the row it reads from a queue table.
        if keyword == "SELECT" || keyword == "SEL", rest.first?.word == "AND", rest.dropFirst().first?.word == "CONSUME" {
            return .change
        }
        if readKeywords.contains(keyword) { return .read }
        switch keyword {
        case "WITH":
            return rest.contains { token in token.word.map { writeKeywords.contains($0) } ?? false } ? .change : .read
        case "LOCKING", "LOCK":
            return lockedStatementKind(rest)
        case "BT":
            return .begin
        case "ET":
            return .end
        case "BEGIN":
            return rest.first?.word == "TRANSACTION" ? .begin : .change
        case "END":
            return rest.first?.word == "TRANSACTION" ? .end : .change
        case "COMMIT":
            return .commit
        case "ROLLBACK", "ABORT":
            return .rollback
        default:
            return .change
        }
    }

    // `LOCKING ROW FOR ACCESS SELECT ...`: the statement the modifier applies to follows the lock type.
    private static func lockedStatementKind(_ tokens: ArraySlice<TeradataRequestTokens.Token>) -> TeradataStatementKind {
        var sawLockType = false
        for index in tokens.indices {
            guard let word = tokens[index].word else { continue }
            if sawLockType {
                if lockTypeModifiers.contains(word) { continue }
                return kind(of: tokens[index...])
            }
            sawLockType = lockTypes.contains(word)
        }
        return .change
    }
}

// Splits a request at each `;` outside quotes and comments, keeping each statement's words uppercased.
enum TeradataRequestTokens {
    enum Token: Equatable {
        case word(String)
        case quoted
        case symbol(UInt8)

        var word: String? {
            guard case .word(let word) = self else { return nil }
            return word
        }
    }

    static func statements(in request: String) -> [[Token]] {
        let bytes = Array(request.utf8)
        var statements: [[Token]] = []
        var current: [Token] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            let following = index + 1 < bytes.count ? bytes[index + 1] : 0
            switch byte {
            case UInt8(ascii: ";"):
                if !current.isEmpty { statements.append(current) }
                current = []
                index += 1
            case UInt8(ascii: "'"), UInt8(ascii: "\""):
                current.append(.quoted)
                index = endOfQuoted(bytes, from: index)
            case UInt8(ascii: "-") where following == UInt8(ascii: "-"):
                index = endOfLineComment(bytes, from: index)
            case UInt8(ascii: "/") where following == UInt8(ascii: "*"):
                index = endOfBlockComment(bytes, from: index)
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), 0x0B, 0x0C:
                index += 1
            default:
                guard isWordByte(byte) else {
                    current.append(.symbol(byte))
                    index += 1
                    continue
                }
                let start = index
                while index < bytes.count, isWordByte(bytes[index]) { index += 1 }
                current.append(.word(String(bytes: bytes[start..<index], encoding: .utf8)?.uppercased() ?? ""))
            }
        }
        if !current.isEmpty { statements.append(current) }
        return statements
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "$"), UInt8(ascii: "#"):
            return true
        default:
            return byte >= 0x80
        }
    }

    // A doubled quote stands for itself; an unclosed one runs to the end.
    private static func endOfQuoted(_ bytes: [UInt8], from start: Int) -> Int {
        let quote = bytes[start]
        var index = start + 1
        while index < bytes.count {
            guard bytes[index] == quote else {
                index += 1
                continue
            }
            guard index + 1 < bytes.count, bytes[index + 1] == quote else { return index + 1 }
            index += 2
        }
        return index
    }

    // A carriage return ends the comment too, which leans toward reading more of the request as code.
    private static func endOfLineComment(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start + 2
        while index < bytes.count, bytes[index] != UInt8(ascii: "\n"), bytes[index] != UInt8(ascii: "\r") {
            index += 1
        }
        return index
    }

    private static func endOfBlockComment(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start + 2
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "*"), bytes[index + 1] == UInt8(ascii: "/") { return index + 2 }
            index += 1
        }
        return bytes.count
    }
}

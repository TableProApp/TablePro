//
//  QueryClassifier+Cypher.swift
//  TablePro
//

import Foundation

extension QueryClassifier {
    static func cypherClassification(_ text: String) -> QueryClassification {
        cypherReadings(of: text).reduce(.safe) { worst, code in
            worst.escalated(with: cypherClassification(code: code))
        }
    }

    static func cypherDeletesUnfiltered(_ text: String) -> Bool {
        cypherReadings(of: text).contains { code in
            code.split(separator: ";").contains { statement in
                let words = Set(cypherClauseWords(in: Array(statement)).map(\.text))
                return words.contains("DELETE") && words.isDisjoint(with: ["WHERE", "LIMIT"]) && !statement.contains("{")
            }
        }
    }

    // Neo4j's parser decodes `\uXXXX` before it lexes, so `\u0044ELETE` is DELETE and `\u0060` closes a backtick
    // name. A server that does not decode reads the text as written, so both readings are tiered.
    private static func cypherReadings(of text: String) -> [[Character]] {
        let decoded = cypherDecodingUnicodeEscapes(text)
        return decoded == text ? [cypherCode(text)] : [cypherCode(text), cypherCode(decoded)]
    }

    private static func cypherClassification(code: [Character]) -> QueryClassification {
        var result = QueryClassification.safe
        for word in cypherClauseWords(in: code) {
            switch word.text {
            case "DROP", "DENY", "REVOKE":
                result = result.escalated(to: .destructive)
            case "CREATE", "INSERT", "MERGE", "SET", "REMOVE", "DELETE", "FOREACH", "GRANT":
                result = result.escalated(to: .write)
            case let admin where cypherAdminObjects[admin] != nil:
                // Only before the object it administers, so a variable named `start` stays a read.
                if let next = cypherNextWord(in: code, after: word.end), cypherAdminObjects[admin]?.contains(next) == true {
                    result = result.escalated(to: .write)
                }
            case "LOAD":
                result = result.markingUnsafeSurface()
            case "CALL":
                if let procedure = cypherProcedureName(in: code, after: word.end),
                   !cypherReadProcedures.contains(where: procedure.hasPrefix) {
                    result = result.escalated(to: .write)
                }
            default:
                continue
            }
        }
        return result
    }

    static let cypherAdminObjects: [String: Set<String>] = [
        "ALTER": ["USER", "CURRENT", "DATABASE", "SERVER", "ALIAS"],
        "RENAME": ["USER", "ROLE", "SERVER"],
        "START": ["DATABASE"],
        "STOP": ["DATABASE"],
        "TERMINATE": ["TRANSACTION", "TRANSACTIONS"],
        "ENABLE": ["SERVER"],
        "DEALLOCATE": ["DATABASE", "DATABASES"],
        "REALLOCATE": ["DATABASE", "DATABASES"]
    ]

    static let cypherReadProcedures: [String] = [
        "db.labels", "db.relationshiptypes", "db.propertykeys", "db.schema.", "db.info", "db.ping",
        "db.indexes", "db.constraints", "db.index.fulltext.query", "db.index.vector.query",
        "dbms.components", "dbms.showcurrentuser", "dbms.procedures", "dbms.functions", "apoc.meta."
    ]

    // JavaCC's unicode-escape rule: a backslash after an even run of backslashes, one or more `u`, four hex digits.
    static func cypherDecodingUnicodeEscapes(_ text: String) -> String {
        let units = Array(text.utf16)
        let backslash = UInt16(UInt8(ascii: "\\"))
        let letterU = UInt16(UInt8(ascii: "u"))
        var decoded: [UInt16] = []
        decoded.reserveCapacity(units.count)
        var backslashRun = 0
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == backslash, backslashRun.isMultiple(of: 2), index + 1 < units.count, units[index + 1] == letterU {
                var hexStart = index + 1
                while hexStart < units.count, units[hexStart] == letterU { hexStart += 1 }
                if hexStart + 4 <= units.count,
                   let scalar = UInt16(String(decoding: units[hexStart ..< hexStart + 4], as: UTF16.self), radix: 16) {
                    decoded.append(scalar)
                    backslashRun = 0
                    index = hexStart + 4
                    continue
                }
            }
            backslashRun = unit == backslash ? backslashRun + 1 : 0
            decoded.append(unit)
            index += 1
        }
        return String(decoding: decoded, as: UTF16.self)
    }

    // Strings and comments blanked, each backtick name replaced by `_q`, which no clause or procedure matches.
    // Cypher has no `--` comment: `(a)-- (b)` is a pattern.
    private static func cypherCode(_ text: String) -> [Character] {
        let characters = Array(text)
        var code: [Character] = []
        code.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            switch character {
            case "'", "\"":
                index += 1
                while index < characters.count, characters[index] != character {
                    index += characters[index] == "\\" ? 2 : 1
                }
                code.append(" ")
            case "`":
                index += 1
                while index < characters.count {
                    if characters[index] == "`" {
                        guard index + 1 < characters.count, characters[index + 1] == "`" else { break }
                        index += 1
                    }
                    index += 1
                }
                code += ["_", "q"]
            case "/" where next == "/":
                while index < characters.count, !characters[index].isNewline { index += 1 }
                code.append("\n")
            case "/" where next == "*":
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index += 1
                code.append(" ")
            default:
                code.append(character)
            }
            index += 1
        }
        return code
    }

    // A word after `.`, `:` or `$`, or before `:`, is a property, a label, a parameter or a map key.
    private static func cypherClauseWords(in code: [Character]) -> [(text: String, end: Int)] {
        var words: [(text: String, end: Int)] = []
        var index = 0
        while index < code.count {
            guard code[index].isLetter || code[index] == "_" else {
                index += 1
                continue
            }
            let start = index
            while index < code.count, code[index].isLetter || code[index].isNumber || code[index] == "_" {
                index += 1
            }
            if let before = code[..<start].last(where: { !$0.isWhitespace }), ".:$".contains(before) { continue }
            if code[index...].first(where: { !$0.isWhitespace }) == ":" { continue }
            words.append((String(code[start ..< index]).uppercased(), index))
        }
        return words
    }

    private static func cypherNextWord(in code: [Character], after end: Int) -> String? {
        guard let start = code[end...].firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let word = code[start...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return word.isEmpty ? nil : String(word).uppercased()
    }

    // Nil for a `CALL { ... }` or `CALL (x) { ... }` subquery, whose own clauses are tiered.
    private static func cypherProcedureName(in code: [Character], after end: Int) -> String? {
        guard let start = code[end...].firstIndex(where: { !$0.isWhitespace }), code[start] != "{" else { return nil }
        if code[start] == "(" {
            let afterScope = code[start...].firstIndex(of: ")").flatMap { close in
                code[(close + 1)...].first { !$0.isWhitespace }
            }
            return afterScope == "{" ? nil : ""
        }
        let name = code[start...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        return String(name).lowercased()
    }
}

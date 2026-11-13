//
//  QueryClassifier+Cypher.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

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

    // Cypher Manual, clauses index (Cypher 25, Neo4j 2026.04): the clauses a query opens with. Administration opens
    // with any other word, including the ones a later server adds.
    static let cypherHeadClauses: Set<String> = [
        "MATCH", "OPTIONAL", "RETURN", "WITH", "UNWIND", "FOR", "CALL", "MERGE", "CREATE", "INSERT", "FOREACH",
        "FINISH", "LET", "FILTER", "WHEN", "SHOW"
    ]

    // Clauses upper case, procedures lower case as `cypherReadProcedures` compares them.
    static func cypherDataCommands(_ text: String) -> [DataCommand]? {
        var commands: [DataCommand] = []
        for code in cypherReadings(of: text) {
            for statement in code.split(separator: ";") where statement.contains(where: { !$0.isWhitespace }) {
                guard let named = cypherDataCommands(statement: Array(statement)) else { return [.refused] }
                commands += named
            }
        }
        guard commands.isEmpty else { return commands }
        return cypherClassification(text).tier == .safe ? [.read] : [.refused]
    }

    private static func cypherDataCommands(statement code: [Character]) -> [DataCommand]? {
        guard let head = cypherHeadClause(in: code), cypherHeadClauses.contains(head) else { return nil }
        let words = cypherClauseWords(in: code)
        var commands: [DataCommand] = []
        for (position, word) in words.enumerated() {
            let previous = position > 0 ? words[position - 1].text : nil
            switch word.text {
            case "DROP", "DENY", "REVOKE", "GRANT", "LOAD":
                return nil
            case "CREATE" where previous == "ON":
                // MERGE's `ON CREATE SET`.
                guard cypherNextWord(in: code, after: word.end) == "SET" else { return nil }
            case "CREATE":
                // `CREATE INDEX`, `CREATE USER`, `CREATE OR REPLACE DATABASE` name an object where a pattern goes.
                guard cypherCreatesPattern(in: code, after: word.end) else { return nil }
                commands.append(.named("CREATE"))
            case "DELETE":
                commands.append(.named(previous == "DETACH" ? "DETACH DELETE" : "DELETE"))
            case "MERGE", "SET", "REMOVE", "FOREACH", "INSERT":
                commands.append(.named(word.text))
            case "CALL":
                guard let procedure = cypherProcedureName(in: code, after: word.end) else { continue }
                guard !procedure.isEmpty, !procedure.split(separator: ".").contains("_q") else { return nil }
                if !cypherReadProcedures.contains(where: procedure.hasPrefix) {
                    commands.append(.named(procedure))
                }
            case let admin where cypherAdminObjects[admin] != nil:
                if let next = cypherNextWord(in: code, after: word.end), cypherAdminObjects[admin]?.contains(next) == true {
                    return nil
                }
            default:
                continue
            }
        }
        return commands
    }

    // The first clause after the prefixes a query may carry: `CYPHER` with its version and options, `EXPLAIN` or
    // `PROFILE`, and `USE` with its graph.
    private static func cypherHeadClause(in code: [Character]) -> String? {
        var index = 0
        while let word = cypherWord(in: code, from: &index) {
            switch word {
            case "CYPHER":
                cypherSkipQueryOptions(in: code, from: &index)
            case "EXPLAIN", "PROFILE":
                continue
            case "USE":
                cypherSkipGraph(in: code, from: &index)
            default:
                return word
            }
        }
        return nil
    }

    private static func cypherWord(in code: [Character], from index: inout Int) -> String? {
        while index < code.count, code[index].isWhitespace { index += 1 }
        let start = index
        while index < code.count, code[index].isLetter || code[index].isNumber || code[index] == "_" { index += 1 }
        return start < index ? String(code[start ..< index]).uppercased() : nil
    }

    // `CYPHER 25 runtime=slotted`: a version, then `name=value` options.
    private static func cypherSkipQueryOptions(in code: [Character], from index: inout Int) {
        while index < code.count, code[index].isWhitespace { index += 1 }
        while index < code.count, code[index].isNumber || code[index] == "." { index += 1 }
        while true {
            var probe = index
            guard cypherWord(in: code, from: &probe) != nil else { return }
            while probe < code.count, code[probe].isWhitespace { probe += 1 }
            guard probe < code.count, code[probe] == "=" else { return }
            probe += 1
            guard cypherWord(in: code, from: &probe) != nil else { return }
            index = probe
        }
    }

    // A graph name, dotted or quoted, or a call such as `graph.byName('x')`.
    private static func cypherSkipGraph(in code: [Character], from index: inout Int) {
        while index < code.count, code[index].isWhitespace { index += 1 }
        while index < code.count, code[index].isLetter || code[index].isNumber || code[index] == "_" || code[index] == "." {
            index += 1
        }
        var probe = index
        while probe < code.count, code[probe].isWhitespace { probe += 1 }
        guard probe < code.count, code[probe] == "(" else { return }
        var depth = 0
        while probe < code.count {
            if code[probe] == "(" { depth += 1 }
            if code[probe] == ")" { depth -= 1 }
            probe += 1
            if depth == 0 { break }
        }
        index = probe
    }

    // A pattern, or a path name assigned one: `CREATE (n)`, `CREATE p = (a)-[:R]->(b)`.
    private static func cypherCreatesPattern(in code: [Character], after end: Int) -> Bool {
        guard let start = code[end...].firstIndex(where: { !$0.isWhitespace }) else { return false }
        if code[start] == "(" { return true }
        let name = code[start...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !name.isEmpty,
              let equals = code[(start + name.count)...].firstIndex(where: { !$0.isWhitespace }),
              code[equals] == "="
        else { return false }
        return equals + 1 == code.count || !"=~>".contains(code[equals + 1])
    }

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

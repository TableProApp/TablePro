//
//  QueryClassifier+Cypher.swift
//  TablePro
//

import Foundation

extension QueryClassifier {
    /// Cypher reads unless one of its clauses writes, so every clause word is checked, not only the
    /// first.
    static func cypherClassification(_ text: String) -> QueryClassification {
        let code = cypherCode(text)
        var result = QueryClassification.safe
        for word in cypherClauseWords(in: code) {
            switch word.text {
            case "DROP", "DENY", "REVOKE":
                result = result.escalated(to: .destructive)
            case "CREATE", "INSERT", "MERGE", "SET", "REMOVE", "DELETE", "FOREACH", "GRANT":
                result = result.escalated(to: .write)
            case let admin where cypherAdminObjects[admin] != nil:
                // These lead an administration command and are otherwise ordinary names, so a
                // variable called `start` or `stop` stays a read.
                if let next = cypherNextWord(in: code, after: word.end), cypherAdminObjects[admin]?.contains(next) == true {
                    result = result.escalated(to: .write)
                }
            case "LOAD":
                result = result.markingUnsafeSurface()
            case "CALL":
                // `CALL { ... }` and `CALL (x) { ... }` are subqueries whose own clauses are
                // checked; a procedure is trusted only when it is known to read.
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

    /// Administration commands that write, keyed by their leading word, with the words that may follow it.
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

    /// Procedures that only read, matched by prefix on the lowercased name.
    static let cypherReadProcedures: [String] = [
        "db.labels", "db.relationshiptypes", "db.propertykeys", "db.schema.", "db.info", "db.ping",
        "db.indexes", "db.constraints", "db.index.fulltext.query", "db.index.vector.query",
        "dbms.components", "dbms.showcurrentuser", "dbms.procedures", "dbms.functions", "apoc.meta."
    ]

    /// The text with strings and comments blanked and each backtick-quoted name replaced by `_q`,
    /// which no clause or read-only procedure matches. Cypher has no `--` comment: `(a)-- (b)` is
    /// a pattern, so the SQL comment rules cannot be reused here.
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

    /// The clause words, uppercased. A word after `.`, `:` or `$`, or before `:`, is a property, a
    /// label, a parameter or a map key, so `n.set` or `{delete: 1}` is never read as a clause.
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

    /// The procedure a `CALL` names, or nil for a subquery.
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

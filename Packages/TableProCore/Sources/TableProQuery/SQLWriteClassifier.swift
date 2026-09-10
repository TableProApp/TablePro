import Foundation
import TableProModels

/// Decides whether a statement batch writes, so Safe Mode can block or confirm it.
///
/// The rule is fail-closed: a statement counts as a read only when its leading keyword is one of a
/// short, closed set of read verbs. Everything else writes, including a keyword this classifier has
/// never heard of. A write-keyword allowlist cannot be safe, because anything it has not been
/// taught, or anything hidden behind a leading comment, runs unguarded.
public enum SQLWriteClassifier {
    /// `EXPLAIN` and `PRAGMA` are deliberately absent: `EXPLAIN ANALYZE DELETE …` runs the delete on
    /// PostgreSQL, and `PRAGMA journal_mode = WAL` writes on SQLite and DuckDB.
    private static let readKeywords: Set<String> = ["SHOW", "DESCRIBE", "DESC"]

    /// A `SELECT` reads unless it materialises a table, which `SELECT … INTO` does on SQL Server and
    /// `SELECT … INTO OUTFILE` does on MySQL. Mirrors QueryClassifier.swift:288-291.
    private static let readUnlessIntoKeywords: Set<String> = ["SELECT", "TABLE", "VALUES"]

    /// Statement verbs only. `REPLACE`, `INTO` and `COPY` are left out because they collide with
    /// ordinary function and column names, and a CTE that merely calls `replace()` is a read.
    /// Matches QueryClassifier.swift:304-312.
    private static let writeKeywordsInsideCTE: [String] = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "DROP", "TRUNCATE", "ALTER", "CREATE", "INTO"
    ]

    public static func isWriteQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        if databaseType == .redis { return redisWrites(sql) }
        let statements = splitStatements(sql)
        guard !statements.isEmpty else { return false }
        return statements.contains(where: statementWrites)
    }

    private static func statementWrites(_ statement: String) -> Bool {
        let body = strippingLeadingTrivia(statement)
        // Content this cannot name is content it cannot vouch for.
        guard let keyword = leadingKeyword(of: body) else { return true }
        if keyword == "WITH" { return commonTableExpressionWrites(body) }
        if readUnlessIntoKeywords.contains(keyword) {
            return containsWord("INTO", in: maskingLiteralsAndComments(body).uppercased())
        }
        return !readKeywords.contains(keyword)
    }

    /// Redis speaks commands, not SQL, so the SQL path would call every `GET` a write. The read set
    /// is the one QueryClassifier.swift:436-451 already curates for the Mac.
    private static func redisWrites(_ command: String) -> Bool {
        let verb = strippingLeadingTrivia(command)
            .prefix { !$0.isWhitespace }
            .uppercased()
        guard !verb.isEmpty else { return false }
        if verb == "CONFIG" {
            let rest = strippingLeadingTrivia(command)
                .dropFirst(verb.count)
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            return !rest.hasPrefix("GET")
        }
        return !redisReadCommands.contains(verb)
    }

    private static let redisReadCommands: Set<String> = [
        "GET", "MGET", "STRLEN", "GETRANGE", "SUBSTR", "EXISTS", "TYPE", "TTL", "PTTL",
        "EXPIRETIME", "PEXPIRETIME", "KEYS", "SCAN", "RANDOMKEY", "DBSIZE", "DUMP",
        "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HRANDFIELD",
        "HSCAN", "HSTRLEN", "LRANGE", "LLEN", "LINDEX", "LPOS",
        "SMEMBERS", "SISMEMBER", "SMISMEMBER", "SCARD", "SRANDMEMBER", "SSCAN",
        "SDIFF", "SINTER", "SUNION", "SINTERCARD",
        "ZRANGE", "ZRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGE", "ZREVRANGEBYSCORE",
        "ZREVRANGEBYLEX", "ZRANK", "ZREVRANK", "ZSCORE", "ZMSCORE", "ZCARD", "ZCOUNT",
        "ZLEXCOUNT", "ZSCAN", "ZRANDMEMBER", "ZDIFF", "ZINTER", "ZUNION", "ZINTERCARD",
        "XRANGE", "XREVRANGE", "XLEN", "XREAD", "XINFO", "XPENDING", "XAUTOCLAIM",
        "PFCOUNT", "BITCOUNT", "BITPOS", "GETBIT", "BITFIELD_RO",
        "GEOPOS", "GEODIST", "GEOHASH", "GEOSEARCH", "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO",
        "SORT_RO", "OBJECT", "COMMAND", "INFO", "TIME", "LASTSAVE", "PING", "ECHO", "LOLWUT",
        "JSON.GET", "JSON.MGET", "JSON.TYPE", "JSON.OBJKEYS", "JSON.ARRLEN", "JSON.STRLEN",
        "TS.RANGE", "TS.REVRANGE", "TS.GET", "TS.MGET", "TS.INFO", "FT.SEARCH", "FT.INFO"
    ]

    /// A CTE's leading keyword says nothing about what the statement finally does, so the body is
    /// searched for a write verb with its literals and comments blanked out first.
    private static func commonTableExpressionWrites(_ statement: String) -> Bool {
        let masked = maskingLiteralsAndComments(statement).uppercased()
        return writeKeywordsInsideCTE.contains { keyword in
            containsWord(keyword, in: masked)
        }
    }

    private static func containsWord(_ word: String, in haystack: String) -> Bool {
        let characters = Array(haystack)
        let needle = Array(word)
        guard characters.count >= needle.count else { return false }
        for start in 0...(characters.count - needle.count) {
            guard Array(characters[start ..< start + needle.count]) == needle else { continue }
            let before = start > 0 ? characters[start - 1] : " "
            let afterIndex = start + needle.count
            let after = afterIndex < characters.count ? characters[afterIndex] : " "
            if !isIdentifierCharacter(before) && !isIdentifierCharacter(after) { return true }
        }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    private static func leadingKeyword(of statement: String) -> String? {
        var keyword = ""
        for character in statement {
            if isIdentifierCharacter(character) {
                keyword.append(character)
            } else {
                break
            }
        }
        return keyword.isEmpty ? nil : keyword.uppercased()
    }

    private static func strippingLeadingTrivia(_ statement: String) -> String {
        var rest = Substring(statement)
        while true {
            let beforeTrim = rest
            rest = rest.drop(while: { $0.isWhitespace })
            if rest.hasPrefix("--") {
                rest = rest.drop(while: { !$0.isNewline })
            } else if rest.hasPrefix("/*") {
                rest = rest.dropFirst(2)
                while !rest.isEmpty, !rest.hasPrefix("*/") { rest = rest.dropFirst() }
                rest = rest.hasPrefix("*/") ? rest.dropFirst(2) : rest
            }
            if rest == beforeTrim { break }
        }
        return String(rest)
    }

    /// Splits on semicolons that are not inside a string, an identifier quote, or a comment.
    private static func splitStatements(_ sql: String) -> [String] {
        let characters = Array(sql)
        let quoted = quotedOrCommentMask(characters)
        var statements: [String] = []
        var current = ""

        for (index, character) in characters.enumerated() {
            if character == ";", !quoted[index] {
                appendIfMeaningful(current, to: &statements)
                current = ""
                continue
            }
            current.append(character)
        }
        appendIfMeaningful(current, to: &statements)
        return statements
    }

    private static func appendIfMeaningful(_ statement: String, to statements: inout [String]) {
        let body = strippingLeadingTrivia(statement).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        statements.append(statement)
    }

    private static func maskingLiteralsAndComments(_ sql: String) -> String {
        let characters = Array(sql)
        let quoted = quotedOrCommentMask(characters)
        return String(characters.enumerated().map { quoted[$0.offset] ? " " : $0.element })
    }

    /// One pass marking every position that sits inside a string literal, a quoted identifier, or a
    /// comment. Doubled and backslash-escaped quotes do not end a literal. Splitting and blanking
    /// both read this rather than re-deriving the state, so neither can drift from the other.
    private static func quotedOrCommentMask(_ characters: [Character]) -> [Bool] {
        var mask = [Bool](repeating: false, count: characters.count)
        var index = 0
        var quote: Character?

        while index < characters.count {
            let character = characters[index]
            let following = index + 1 < characters.count ? characters[index + 1] : nil

            if let open = quote {
                mask[index] = true
                // A backslash is not an escape under PostgreSQL's standard_conforming_strings, which
                // PostgreSQLDriver sets on. Treating it as one would swallow the terminating quote
                // and hide the rest of the batch, so it is left alone: ending a literal early splits
                // more statements, and more statements can only classify toward write.
                if character == open {
                    if following == open {
                        mask[index + 1] = true
                        index += 2
                        continue
                    }
                    quote = nil
                }
                index += 1
                continue
            }

            if character == "-", following == "-" {
                while index < characters.count, !characters[index].isNewline {
                    mask[index] = true
                    index += 1
                }
                continue
            }

            if character == "/", following == "*" {
                mask[index] = true
                mask[index + 1] = true
                index += 2
                while index < characters.count {
                    if characters[index] == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                        mask[index] = true
                        mask[index + 1] = true
                        index += 2
                        break
                    }
                    mask[index] = true
                    index += 1
                }
                continue
            }

            if character == "'" || character == "\"" || character == "`" {
                quote = character
                mask[index] = true
                index += 1
                continue
            }

            index += 1
        }
        return mask
    }
}

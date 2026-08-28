//
//  QueryClassifier.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum QueryTier: Sendable, Equatable {
    case safe
    case write
    case destructive
}

struct QueryClassification: Sendable, Equatable {
    let tier: QueryTier
    let reachesFilesystemOrExecutesCode: Bool

    static let safe = QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: false)

    func escalated(to other: QueryTier) -> QueryClassification {
        QueryClassification(
            tier: QueryClassification.worse(tier, other),
            reachesFilesystemOrExecutesCode: reachesFilesystemOrExecutesCode
        )
    }

    func markingUnsafeSurface() -> QueryClassification {
        QueryClassification(
            tier: QueryClassification.worse(tier, .write),
            reachesFilesystemOrExecutesCode: true
        )
    }

    static func worse(_ lhs: QueryTier, _ rhs: QueryTier) -> QueryTier {
        if lhs == .destructive || rhs == .destructive { return .destructive }
        if lhs == .write || rhs == .write { return .write }
        return .safe
    }
}

enum QueryClassifier {
    static func classify(_ sql: String, databaseType: DatabaseType) -> QueryClassification {
        let trimmed = strippingLeadingComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .safe }
        if let redis = redisClassification(trimmed, databaseType: databaseType) { return redis }
        if let document = documentStoreClassification(trimmed, databaseType: databaseType) { return document }
        return sqlClassification(trimmed)
    }

    static func isWriteQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        classify(sql, databaseType: databaseType).tier != .safe
    }

    static func isDangerousQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        let classification = classify(sql, databaseType: databaseType)
        if classification.tier == .destructive { return true }
        guard databaseType != .redis else { return false }
        let trimmed = strippingLeadingComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)
        guard leadingKeyword(of: trimmed) == "DELETE" else { return false }
        return !hasWhereClause(trimmed)
    }

    static func classifyTier(_ sql: String, databaseType: DatabaseType) -> QueryTier {
        classify(sql, databaseType: databaseType).tier
    }

    static func reachesFilesystemOrExecutesCode(_ sql: String, databaseType: DatabaseType) -> Bool {
        classify(sql, databaseType: databaseType).reachesFilesystemOrExecutesCode
    }

    static func isMultiStatement(_ sql: String, databaseType: DatabaseType) -> Bool {
        QueryStatementScanner.executableStatements(
            in: sql,
            model: QueryStatementModel.forDatabaseType(databaseType),
            dialect: SqlDialect.from(databaseTypeId: databaseType.rawValue)
        ).count > 1
    }

    static func isExplainStatement(_ sql: String) -> Bool {
        let upper = strippingLeadingComments(sql).uppercased()
        return explainPrefixes.contains { prefix in
            guard upper.hasPrefix(prefix), let boundary = upper.dropFirst(prefix.count).first else {
                return false
            }
            return boundary == "(" || boundary.isWhitespace
        }
    }

    static func explainedStatement(in sql: String) -> String? {
        let trimmed = strippingLeadingComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)
        let keyword = leadingKeyword(of: trimmed)
        guard explainPrefixes.contains(keyword) else { return nil }
        return explainInnerStatement(trimmed, keyword: keyword)?.statement
    }

    /// A parenthesised query expression is idiomatic when each arm of a set operation carries its
    /// own ORDER BY, so the opening parens are skipped to reach the keyword that classifies the
    /// statement. Skipping cannot loosen the classification: an unrecognised keyword still falls to
    /// the write arm, and the body-wide filesystem and destructive scans run over the whole text.
    static func leadingKeyword(of sql: String) -> String {
        var remaining = strippingLeadingComments(sql)[...]
        while remaining.first == "(" {
            remaining = remaining.dropFirst().drop { $0.isWhitespace }
            guard remaining.hasPrefix("--") || remaining.hasPrefix("/*") else { continue }
            remaining = strippingLeadingComments(String(remaining))[...]
        }
        return remaining.prefix { $0.isLetter || $0.isNumber || $0 == "_" }.uppercased()
    }

    static func strippingLeadingComments(_ sql: String) -> String {
        var remaining = sql[...]
        while true {
            let trimmed = remaining.drop { $0.isWhitespace }
            if trimmed.hasPrefix("--") {
                guard let newline = trimmed.firstIndex(of: "\n") else { return "" }
                remaining = trimmed[trimmed.index(after: newline)...]
            } else if trimmed.hasPrefix("/*") {
                guard let close = trimmed.range(of: "*/") else { return "" }
                remaining = trimmed[close.upperBound...]
            } else {
                return String(trimmed)
            }
        }
    }

    static func strippingStringLiterals(_ sql: String) -> String {
        var output = ""
        output.reserveCapacity(sql.count)
        var characters = Array(sql)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "'" || character == "\"" || character == "`" {
                index = skipQuoted(characters, from: index, quote: character, into: &output)
                continue
            }
            if character == "$", let end = skipDollarQuoted(characters, from: index) {
                output.append(" ")
                index = end
                continue
            }
            if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
                output.append(" ")
                continue
            }
            output.append(character)
            index += 1
        }
        return output
    }

    private static func skipQuoted(
        _ characters: [Character],
        from start: Int,
        quote: Character,
        into output: inout String
    ) -> Int {
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                index += 2
                continue
            }
            if character == quote {
                if index + 1 < characters.count, characters[index + 1] == quote {
                    index += 2
                    continue
                }
                index += 1
                break
            }
            index += 1
        }
        output.append(" ")
        return index
    }

    private static func skipDollarQuoted(_ characters: [Character], from start: Int) -> Int? {
        var cursor = start + 1
        var tag = ""
        while cursor < characters.count, characters[cursor] != "$" {
            let character = characters[cursor]
            guard character.isLetter || character.isNumber || character == "_" else { return nil }
            tag.append(character)
            cursor += 1
        }
        guard cursor < characters.count else { return nil }
        let delimiter = Array("$\(tag)$")
        var index = cursor + 1
        while index + delimiter.count <= characters.count {
            if Array(characters[index..<(index + delimiter.count)]) == delimiter {
                return index + delimiter.count
            }
            index += 1
        }
        return characters.count
    }
}

private extension QueryClassifier {
    static let explainPrefixes: [String] = ["EXPLAIN", "ANALYZE"]

    static let whereClauseRegex = try? NSRegularExpression(pattern: "\\sWHERE\\s", options: [])

    static let destructiveKeywords: Set<String> = ["DROP", "TRUNCATE"]

    static let filesystemOrCodeKeywords: Set<String> = [
        "COPY", "ATTACH", "DETACH", "DO", "LOAD", "INSTALL", "IMPORT", "EXPORT",
        "BACKUP", "RESTORE", "DUMP", "SOURCE", "UNLOAD"
    ]

    static let writeKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "UPSERT",
        "ALTER", "CREATE", "RENAME", "GRANT", "REVOKE", "COMMENT", "DENY",
        "CALL", "EXEC", "EXECUTE", "PREPARE", "DEALLOCATE",
        "SET", "RESET", "LOCK", "UNLOCK", "USE", "PRAGMA",
        "VACUUM", "REINDEX", "CLUSTER", "REFRESH", "ANALYZE", "OPTIMIZE", "REPAIR", "CHECK",
        "BEGIN", "START", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "END", "ABORT",
        "DECLARE", "FETCH", "CLOSE", "MOVE", "DISCARD", "CHECKPOINT", "FLUSH",
        "KILL", "SHUTDOWN", "PURGE", "MSCK", "BATCH", "APPLY",
        "DEFINE", "REMOVE", "RELATE", "LET", "SECURITY", "LISTEN", "UNLISTEN", "NOTIFY"
    ]

    static let readOnlyKeywords: Set<String> = [
        "SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "VALUES", "TABLE",
        "HELP", "INFO", "PRINT", "EXPLAIN", "ANALYZE"
    ]

    static let statementStartKeywords: Set<String> = [
        "SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "UPSERT",
        "CREATE", "ALTER", "DROP", "TRUNCATE", "TABLE", "VALUES", "CALL", "EXECUTE", "COPY", "DO"
    ]

    static let filesystemMarkers: [String] = [
        "INTO OUTFILE", "INTO DUMPFILE", "TO PROGRAM", "FROM PROGRAM", "VACUUM INTO",
        "LOAD_FILE(", "PG_READ_FILE(", "PG_READ_BINARY_FILE(", "PG_LS_DIR(",
        "LO_IMPORT(", "LO_EXPORT(", "PG_FILE_WRITE(", "LOAD_EXTENSION(",
        "READFILE(", "WRITEFILE(", "FN_GET_AUDIT_FILE(", "XP_CMDSHELL", "SP_OACREATE"
    ]

    static func hasWhereClause(_ trimmed: String) -> Bool {
        let uppercased = strippingStringLiterals(trimmed).uppercased()
        let range = NSRange(uppercased.startIndex..., in: uppercased)
        return whereClauseRegex?.firstMatch(in: uppercased, options: [], range: range) != nil
    }

    static func sqlClassification(_ trimmed: String) -> QueryClassification {
        let body = strippingStringLiterals(trimmed).uppercased()
        let touchesUnsafeSurface = filesystemMarkers.contains { body.contains($0) }
        let base = keywordClassification(trimmed, body: body)
        return touchesUnsafeSurface ? base.markingUnsafeSurface() : base
    }

    static func keywordClassification(_ trimmed: String, body: String) -> QueryClassification {
        let keyword = leadingKeyword(of: trimmed)

        if keyword == "EXPLAIN" || keyword == "ANALYZE" {
            return explainClassification(trimmed, body: body, keyword: keyword)
        }

        if filesystemOrCodeKeywords.contains(keyword) {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: true)
        }

        if destructiveKeywords.contains(keyword) {
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: false)
        }

        if keyword == "ALTER" {
            let tier: QueryTier = body.range(of: " DROP ", options: .literal) != nil ? .destructive : .write
            return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: false)
        }

        if keyword == "WITH" {
            return commonTableExpressionClassification(body)
        }

        if keyword == "SELECT" || keyword == "TABLE" || keyword == "VALUES" {
            guard containsWord(body, "INTO") else { return .safe }
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        }

        if writeKeywords.contains(keyword) {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        }

        if readOnlyKeywords.contains(keyword) {
            return .safe
        }

        return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
    }

    static func commonTableExpressionClassification(_ body: String) -> QueryClassification {
        for keyword in ["DROP", "TRUNCATE"] where containsWord(body, keyword) {
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: false)
        }
        for keyword in ["INSERT", "UPDATE", "DELETE", "MERGE"] where containsWord(body, keyword) {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        }
        return .safe
    }

    static func explainClassification(
        _ trimmed: String,
        body: String,
        keyword: String
    ) -> QueryClassification {
        guard let inner = explainInnerStatement(trimmed, keyword: keyword) else {
            let tier: QueryTier = keyword == "ANALYZE" ? .write : .safe
            return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: false)
        }
        let innerClassification = sqlClassification(inner.statement)
        guard inner.executesStatement else {
            return QueryClassification(
                tier: .safe,
                reachesFilesystemOrExecutesCode: innerClassification.reachesFilesystemOrExecutesCode
            )
        }
        return innerClassification
    }

    static func explainInnerStatement(
        _ trimmed: String,
        keyword: String
    ) -> (statement: String, executesStatement: Bool)? {
        var remainder = Substring(trimmed).dropFirst(keyword.count)
        var options = keyword == "ANALYZE" ? "ANALYZE" : ""
        var statementTriviaStart: String.Index?
        while true {
            remainder = remainder.drop { $0.isWhitespace }
            guard let first = remainder.first else { return nil }
            if remainder.hasPrefix("--") {
                statementTriviaStart = statementTriviaStart ?? remainder.startIndex
                guard let newline = remainder.firstIndex(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
                remainder = remainder[remainder.index(after: newline)...]
                continue
            }
            if remainder.hasPrefix("/*") {
                statementTriviaStart = statementTriviaStart ?? remainder.startIndex
                guard let afterComment = remainderAfterBlockComment(in: remainder) else { return nil }
                remainder = afterComment
                continue
            }
            if first == "(" {
                statementTriviaStart = nil
                var depth = 0
                var index = remainder.startIndex
                while index < remainder.endIndex {
                    if remainder[index] == "(" { depth += 1 }
                    if remainder[index] == ")" {
                        depth -= 1
                        if depth == 0 {
                            index = remainder.index(after: index)
                            break
                        }
                    }
                    index = remainder.index(after: index)
                }
                options += " " + remainder[remainder.startIndex..<index].uppercased()
                remainder = remainder[index...]
                continue
            }
            let token = remainder.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !token.isEmpty else {
                if first == "=" || first == "," {
                    statementTriviaStart = nil
                    remainder = remainder.dropFirst()
                    continue
                }
                return nil
            }
            let upperToken = token.uppercased()
            if statementStartKeywords.contains(upperToken) {
                let statement = statementTriviaStart.map { trimmed[$0...] } ?? remainder
                return (String(statement), options.contains("ANALYZE"))
            }
            options += " " + upperToken
            statementTriviaStart = nil
            remainder = remainder.dropFirst(token.count)
        }
    }

    static func remainderAfterBlockComment(in sql: Substring) -> Substring? {
        var depth = 1
        var index = sql.index(sql.startIndex, offsetBy: 2)
        while index < sql.endIndex {
            let next = sql.index(after: index)
            guard next < sql.endIndex else { return nil }
            let pair = sql[index...next]
            if pair == "/*" {
                depth += 1
                index = sql.index(after: next)
            } else if pair == "*/" {
                depth -= 1
                let afterClose = sql.index(after: next)
                if depth == 0 { return sql[afterClose...] }
                index = afterClose
            } else {
                index = next
            }
        }
        return nil
    }

    static func containsWord(_ body: String, _ word: String) -> Bool {
        var searchRange = body.startIndex..<body.endIndex
        while let found = body.range(of: word, options: .literal, range: searchRange) {
            let beforeOk = found.lowerBound == body.startIndex
                || !isIdentifierCharacter(body[body.index(before: found.lowerBound)])
            let afterOk = found.upperBound == body.endIndex
                || !isIdentifierCharacter(body[found.upperBound])
            if beforeOk, afterOk { return true }
            guard found.upperBound < body.endIndex else { return false }
            searchRange = found.upperBound..<body.endIndex
        }
        return false
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

private extension QueryClassifier {
    static let redisReadCommands: Set<String> = [
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

    static let redisDestructiveCommands: Set<String> = [
        "FLUSHDB", "FLUSHALL", "SHUTDOWN", "MIGRATE", "SWAPDB", "REPLICAOF", "SLAVEOF",
        "CLUSTER", "FAILOVER", "RESET"
    ]

    static let redisCodeExecutionCommands: Set<String> = [
        "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO",
        "FUNCTION", "SCRIPT", "MODULE", "DEBUG"
    ]

    static let redisFilesystemCommands: Set<String> = [
        "SAVE", "BGSAVE", "BGREWRITEAOF", "DEBUG"
    ]

    static func redisClassification(
        _ trimmed: String,
        databaseType: DatabaseType
    ) -> QueryClassification? {
        guard databaseType == .redis else { return nil }
        let command = trimmed.prefix { !$0.isWhitespace }.uppercased()
        guard !command.isEmpty else { return .safe }

        let touchesUnsafeSurface = redisCodeExecutionCommands.contains(command)
            || redisFilesystemCommands.contains(command)

        if command == "CONFIG" {
            let rest = trimmed.dropFirst(command.count).trimmingCharacters(in: .whitespaces).uppercased()
            let tier: QueryTier = rest.hasPrefix("GET") ? .safe : .destructive
            return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: false)
        }

        if redisDestructiveCommands.contains(command) || command == "DEBUG" {
            return QueryClassification(
                tier: .destructive,
                reachesFilesystemOrExecutesCode: touchesUnsafeSurface
            )
        }

        if redisReadCommands.contains(command) {
            return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: false)
        }

        return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
    }

    static let mongoReadMethods: Set<String> = [
        "find", "findone", "aggregate", "count", "countdocuments", "estimateddocumentcount",
        "distinct", "explain", "getindexes", "listindexes", "listcollections", "getcollectionnames",
        "getcollectioninfos", "stats", "totalsize", "datasize", "watch", "getindexkeys", "help",
        "hello", "ismaster", "serverstatus", "dbstats", "collstats", "validate", "getshardversion"
    ]

    static let mongoDestructiveMethods: Set<String> = [
        "drop", "dropdatabase", "dropindex", "dropindexes", "dropcollection", "deletemany",
        "removeall", "renamecollection"
    ]

    static let mongoCodeExecutionMarkers: [String] = [
        "$where", "$function", "$accumulator", "mapreduce", ".eval(", "$out", "$merge"
    ]

    static func documentStoreClassification(
        _ trimmed: String,
        databaseType: DatabaseType
    ) -> QueryClassification? {
        switch databaseType {
        case .mongodb:
            return mongoClassification(trimmed)
        case .etcd:
            return etcdClassification(trimmed)
        case .elasticsearch:
            return elasticsearchClassification(trimmed)
        default:
            return nil
        }
    }

    static func mongoClassification(_ trimmed: String) -> QueryClassification {
        let lowered = trimmed.lowercased()
        let touchesUnsafeSurface = mongoCodeExecutionMarkers.contains { lowered.contains($0) }
        let methods = invokedMethodNames(in: lowered)
        guard !methods.isEmpty else {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        if methods.contains(where: { mongoDestructiveMethods.contains($0) }) {
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        let allRead = methods.allSatisfy { mongoReadMethods.contains($0) }
        let writesThroughPipeline = lowered.contains("$out") || lowered.contains("$merge")
        guard allRead, !writesThroughPipeline else {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
    }

    /// Every method a MongoDB statement invokes, by either spelling.
    ///
    /// The query language is JavaScript, so `db.users.deleteMany({})` and
    /// `db.users["deleteMany"]({})` are the same call. Reading only the dotted form let the bracket
    /// form past the destructive gate, which is what decides whether an external or assistant
    /// client has to confirm before it runs.
    static func invokedMethodNames(in lowered: String) -> [String] {
        dottedMethodNames(in: lowered) + bracketedMethodNames(in: lowered)
    }

    private static func dottedMethodNames(in lowered: String) -> [String] {
        var names: [String] = []
        var current = ""
        var sawDot = false
        for character in lowered {
            if character == "." {
                sawDot = true
                current = ""
                continue
            }
            if character.isLetter || character.isNumber || character == "_" || character == "$" {
                current.append(character)
                continue
            }
            if character == "(", sawDot, !current.isEmpty {
                names.append(current)
            }
            if !character.isWhitespace {
                sawDot = false
            }
            current = ""
        }
        return names
    }

    /// Names taken through bracket access, whether or not they are called on the spot.
    ///
    /// A name is counted even without a following `(`, because `var drop = db.c["drop"]; drop()`
    /// reaches the same command and no scan of the text can follow the binding.
    private static func bracketedMethodNames(in lowered: String) -> [String] {
        var names: [String] = []
        var index = lowered.startIndex

        while let open = lowered[index...].firstIndex(of: "[") {
            var cursor = lowered.index(after: open)
            while cursor < lowered.endIndex, lowered[cursor].isWhitespace {
                cursor = lowered.index(after: cursor)
            }
            guard cursor < lowered.endIndex, lowered[cursor] == "\"" || lowered[cursor] == "'" else {
                index = lowered.index(after: open)
                continue
            }
            let quote = lowered[cursor]
            var name = ""
            cursor = lowered.index(after: cursor)
            while cursor < lowered.endIndex, lowered[cursor] != quote {
                name.append(lowered[cursor])
                cursor = lowered.index(after: cursor)
            }
            if !name.isEmpty { names.append(name) }
            index = cursor < lowered.endIndex ? lowered.index(after: cursor) : lowered.endIndex
        }
        return names
    }

    static let etcdReadCommands: Set<String> = ["GET", "RANGE", "WATCH", "LIST", "STATUS", "VERSION", "ENDPOINT"]

    static func etcdClassification(_ trimmed: String) -> QueryClassification {
        let command = trimmed.prefix { !$0.isWhitespace }.uppercased()
        if command == "SNAPSHOT" || command == "DEFRAG" {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: true)
        }
        if command == "DEL" || command == "DELETE" || command == "COMPACT" || command == "COMPACTION" {
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: false)
        }
        if etcdReadCommands.contains(command) {
            return .safe
        }
        return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
    }

    static let elasticsearchReadPaths: [String] = [
        "_SEARCH", "_COUNT", "_MSEARCH", "_EXPLAIN", "_ANALYZE", "_FIELD_CAPS",
        "_VALIDATE", "_RENDER", "_MAPPING", "_SETTINGS", "_STATS", "_CAT", "_SQL"
    ]

    static func elasticsearchClassification(_ trimmed: String) -> QueryClassification {
        let upper = trimmed.uppercased()
        let verb = upper.prefix { !$0.isWhitespace }
        let touchesUnsafeSurface = upper.contains("_SCRIPTS") || upper.contains("_PAINLESS_EXECUTE")
        if verb == "GET" || verb == "HEAD" {
            return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        if verb == "POST", elasticsearchReadPaths.contains(where: { upper.contains($0) }) {
            return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        if verb == "DELETE" {
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
    }
}

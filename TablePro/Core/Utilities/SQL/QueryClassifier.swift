//
//  QueryClassifier.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum QueryTier {
    case safe
    case write
    case destructive
}

enum QueryClassifier {
    private static let writeQueryPrefixes: [String] = [
        "INSERT ", "UPDATE ", "DELETE ", "REPLACE ",
        "DROP ", "TRUNCATE ", "ALTER ", "CREATE ",
        "RENAME ", "GRANT ", "REVOKE ",
        "MERGE ", "UPSERT ", "CALL ", "EXEC ", "EXECUTE ", "LOAD ",
    ]

    private static let redisWriteCommands: Set<String> = [
        "SET", "DEL", "HSET", "HDEL", "HMSET", "LPUSH", "RPUSH", "LPOP", "RPOP",
        "SADD", "SREM", "ZADD", "ZREM", "EXPIRE", "PERSIST", "RENAME",
        "FLUSHDB", "FLUSHALL", "MSET", "APPEND", "INCR", "DECR", "INCRBY",
        "DECRBY", "SETEX", "PSETEX", "SETNX", "GETSET", "GETDEL",
        "XADD", "XTRIM", "XDEL",
    ]

    private static let redisDangerousCommands: Set<String> = [
        "FLUSHDB", "FLUSHALL", "DEBUG", "SHUTDOWN",
    ]

    private static let explainPrefixes: [String] = ["EXPLAIN", "ANALYZE"]

    private static let whereClauseRegex = try? NSRegularExpression(pattern: "\\sWHERE\\s", options: [])

    static func isWriteQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)

        if databaseType == .redis {
            let firstToken = trimmed.prefix(while: { !$0.isWhitespace }).uppercased()
            if firstToken == "CONFIG" {
                let rest = trimmed.dropFirst(firstToken.count).trimmingCharacters(in: .whitespaces)
                return rest.uppercased().hasPrefix("SET")
            }
            return redisWriteCommands.contains(firstToken)
        }

        let uppercased = trimmed.uppercased()
        if writeQueryPrefixes.contains(where: { uppercased.hasPrefix($0) }) {
            return true
        }

        if uppercased.hasPrefix("WITH ") {
            let dmlKeywords = ["INSERT ", "UPDATE ", "DELETE ", "MERGE "]
            for keyword in dmlKeywords where uppercased.contains(keyword) {
                return true
            }
        }

        return false
    }

    static func isDangerousQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)

        if databaseType == .redis {
            let firstToken = trimmed.prefix(while: { !$0.isWhitespace }).uppercased()
            if firstToken == "CONFIG" {
                let rest = trimmed.dropFirst(firstToken.count).trimmingCharacters(in: .whitespaces)
                return rest.uppercased().hasPrefix("SET")
            }
            return redisDangerousCommands.contains(firstToken)
        }

        let uppercased = trimmed.uppercased()

        if uppercased.hasPrefix("DROP ") {
            return true
        }

        if uppercased.hasPrefix("TRUNCATE ") {
            return true
        }

        if uppercased.hasPrefix("DELETE ") {
            let range = NSRange(uppercased.startIndex..., in: uppercased)
            let hasWhere = whereClauseRegex?.firstMatch(in: uppercased, options: [], range: range) != nil
            return !hasWhere
        }

        return false
    }

    static func classifyTier(_ sql: String, databaseType: DatabaseType) -> QueryTier {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercased = trimmed.uppercased()

        if databaseType == .redis {
            let firstToken = trimmed.prefix(while: { !$0.isWhitespace }).uppercased()
            if firstToken == "FLUSHDB" || firstToken == "FLUSHALL" {
                return .destructive
            }
        } else {
            if uppercased.hasPrefix("DROP ") || uppercased.hasPrefix("TRUNCATE ") {
                return .destructive
            }
            if uppercased.hasPrefix("ALTER ") && uppercased.range(of: " DROP ", options: .literal) != nil {
                return .destructive
            }

            if uppercased.hasPrefix("WITH ") {
                let destructiveKeywords = ["DROP ", "TRUNCATE "]
                for keyword in destructiveKeywords where uppercased.contains(keyword) {
                    return .destructive
                }
                let writeKeywords = ["INSERT ", "UPDATE ", "DELETE ", "MERGE "]
                for keyword in writeKeywords where uppercased.contains(keyword) {
                    return .write
                }
            }
        }

        if isWriteQuery(sql, databaseType: databaseType) {
            return .write
        }

        return .safe
    }

    static func isMultiStatement(_ sql: String, databaseType: DatabaseType) -> Bool {
        SQLStatementScanner.allStatements(
            in: sql,
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

    private static func strippingLeadingComments(_ sql: String) -> String {
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
}

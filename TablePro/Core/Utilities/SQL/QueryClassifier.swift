//
//  QueryClassifier.swift
//  TablePro
//

import Foundation

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
        return writeQueryPrefixes.contains { uppercased.hasPrefix($0) }
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
}

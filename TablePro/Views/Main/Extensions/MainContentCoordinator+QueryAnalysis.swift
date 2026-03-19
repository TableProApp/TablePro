//
//  MainContentCoordinator+QueryAnalysis.swift
//  TablePro
//
//  Write-query and dangerous-query detection for MainContentCoordinator.
//

import Foundation

extension MainContentCoordinator {
    // MARK: - Write Query Detection

    /// Write-operation SQL prefixes blocked in read-only mode
    private static let writeQueryPrefixes: [String] = [
        "INSERT ", "UPDATE ", "DELETE ", "REPLACE ",
        "DROP ", "TRUNCATE ", "ALTER ", "CREATE ",
        "RENAME ", "GRANT ", "REVOKE ",
    ]

    /// Redis commands that modify data
    private static let redisWriteCommands: Set<String> = [
        "SET", "DEL", "HSET", "HDEL", "HMSET", "LPUSH", "RPUSH", "LPOP", "RPOP",
        "SADD", "SREM", "ZADD", "ZREM", "EXPIRE", "PERSIST", "RENAME",
        "FLUSHDB", "FLUSHALL", "MSET", "APPEND", "INCR", "DECR", "INCRBY",
        "DECRBY", "SETEX", "PSETEX", "SETNX", "GETSET", "GETDEL",
        "XADD", "XTRIM", "XDEL",
    ]

    /// Redis commands that are destructive
    private static let redisDangerousCommands: Set<String> = [
        "FLUSHDB", "FLUSHALL", "DEBUG", "SHUTDOWN",
    ]

    /// Check if a SQL statement is a write operation (modifies data or schema)
    func isWriteQuery(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)

        // Redis: check the first token against known write commands
        if connection.type == .redis {
            let firstToken = trimmed.prefix(while: { !$0.isWhitespace }).uppercased()
            // CONFIG SET is a write; plain CONFIG GET is not
            if firstToken == "CONFIG" {
                let rest = trimmed.dropFirst(firstToken.count).trimmingCharacters(in: .whitespaces)
                return rest.uppercased().hasPrefix("SET")
            }
            return Self.redisWriteCommands.contains(firstToken)
        }

        let uppercased = trimmed.uppercased()
        return Self.writeQueryPrefixes.contains { uppercased.hasPrefix($0) }
    }

    // MARK: - Dangerous Query Detection

    /// Pre-compiled regex for detecting WHERE clause in DELETE queries (avoids per-call compilation)
    private static let whereClauseRegex = try? NSRegularExpression(pattern: "\\sWHERE\\s", options: [])

    /// Check if a query is potentially dangerous (DROP, TRUNCATE, DELETE without WHERE)
    func isDangerousQuery(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)

        // Redis: check for destructive commands
        if connection.type == .redis {
            let firstToken = trimmed.prefix(while: { !$0.isWhitespace }).uppercased()
            // CONFIG SET is dangerous
            if firstToken == "CONFIG" {
                let rest = trimmed.dropFirst(firstToken.count).trimmingCharacters(in: .whitespaces)
                return rest.uppercased().hasPrefix("SET")
            }
            return Self.redisDangerousCommands.contains(firstToken)
        }

        let uppercased = trimmed.uppercased()

        // Check for DROP
        if uppercased.hasPrefix("DROP ") {
            return true
        }

        // Check for TRUNCATE
        if uppercased.hasPrefix("TRUNCATE ") {
            return true
        }

        // Check for DELETE without WHERE clause
        if uppercased.hasPrefix("DELETE ") {
            // Check if there's a WHERE clause (handle any whitespace: space, tab, newline)
            let range = NSRange(uppercased.startIndex..., in: uppercased)
            let hasWhere = Self.whereClauseRegex?.firstMatch(in: uppercased, options: [], range: range) != nil
            return !hasWhere
        }

        return false
    }
}

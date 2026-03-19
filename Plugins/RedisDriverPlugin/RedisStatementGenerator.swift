//
//  RedisStatementGenerator.swift
//  RedisDriverPlugin
//
//  Generates Redis commands from tracked cell changes (edit tracking).
//  Plugin-local version using PluginRowChange instead of Core types.
//

import Foundation
import os
import TableProPluginKit

struct RedisStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RedisStatementGenerator")

    let namespaceName: String
    let columns: [String]

    /// Index of the "Key" column (used as primary identifier, like MongoDB's "_id")
    var keyColumnIndex: Int? {
        columns.firstIndex(of: "Key")
    }

    /// Index of the "Value" column
    private var valueColumnIndex: Int? {
        columns.firstIndex(of: "Value")
    }

    /// Index of the "Type" column
    private var typeColumnIndex: Int? {
        columns.firstIndex(of: "Type")
    }

    /// Index of the "TTL" column
    private var ttlColumnIndex: Int? {
        columns.firstIndex(of: "TTL")
    }

    // MARK: - Public API

    /// Generate Redis commands from changes
    func generateStatements(
        from changes: [PluginRowChange],
        insertedRowData: [Int: [String?]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [String?])] {
        var statements: [(statement: String, parameters: [String?])] = []
        var deleteKeys: [String] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                statements += generateInsert(for: change, insertedRowData: insertedRowData)

            case .update:
                statements += generateUpdate(for: change)

            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                if let key = extractKey(from: change) {
                    deleteKeys.append(key)
                }
            }
        }

        // Batch deletes into a single DEL command
        if !deleteKeys.isEmpty {
            let keyList = deleteKeys.map { escapeArgument($0) }.joined(separator: " ")
            let cmd = "DEL \(keyList)"
            statements.append((statement: cmd, parameters: []))
        }

        return statements
    }

    // MARK: - INSERT

    private func generateInsert(
        for change: PluginRowChange,
        insertedRowData: [Int: [String?]]
    ) -> [(statement: String, parameters: [String?])] {
        var statements: [(statement: String, parameters: [String?])] = []

        var key: String?
        var value: String?
        var type: String?
        var ttl: Int?

        if let values = insertedRowData[change.rowIndex] {
            if let ki = keyColumnIndex, ki < values.count {
                key = values[ki]
            }
            if let ti = typeColumnIndex, ti < values.count {
                type = values[ti]
            }
            if let vi = valueColumnIndex, vi < values.count {
                value = values[vi]
            }
            if let ttli = ttlColumnIndex, ttli < values.count, let ttlStr = values[ttli] {
                ttl = Int(ttlStr)
            }
        } else {
            for cellChange in change.cellChanges {
                switch cellChange.columnName {
                case "Key": key = cellChange.newValue
                case "Type": type = cellChange.newValue
                case "Value": value = cellChange.newValue
                case "TTL":
                    if let ttlStr = cellChange.newValue { ttl = Int(ttlStr) }
                default: break
                }
            }
        }

        guard let k = key, !k.isEmpty else {
            Self.logger.warning("Skipping INSERT for namespace '\(self.namespaceName)' - no key")
            return []
        }

        let v = value ?? ""
        let cmd = generateInsertCommand(key: k, value: v, type: type?.lowercased())
        statements.append((statement: cmd, parameters: []))

        if let ttlSeconds = ttl, ttlSeconds > 0 {
            let expireCmd = "EXPIRE \(escapeArgument(k)) \(ttlSeconds)"
            statements.append((statement: expireCmd, parameters: []))
        }

        return statements
    }

    /// Generate the appropriate Redis command based on the data type
    private func generateInsertCommand(key: String, value: String, type: String?) -> String {
        switch type {
        case "hash":
            // Try to parse value as JSON object for HSET key field1 val1 ...
            if let data = value.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var args = "HSET \(escapeArgument(key))"
                for (field, val) in json {
                    args += " \(escapeArgument(field)) \(escapeArgument(String(describing: val)))"
                }
                return args
            }
            return "HSET \(escapeArgument(key)) value \(escapeArgument(value))"
        case "list":
            return "RPUSH \(escapeArgument(key)) \(escapeArgument(value))"
        case "set":
            return "SADD \(escapeArgument(key)) \(escapeArgument(value))"
        case "zset":
            return "ZADD \(escapeArgument(key)) 0 \(escapeArgument(value))"
        default:
            return "SET \(escapeArgument(key)) \(escapeArgument(value))"
        }
    }

    // MARK: - UPDATE

    private func generateUpdate(for change: PluginRowChange) -> [(statement: String, parameters: [String?])] {
        guard !change.cellChanges.isEmpty else { return [] }

        guard let key = extractKey(from: change) else {
            Self.logger.warning("Skipping UPDATE for namespace '\(self.namespaceName)' - no key value")
            return []
        }

        var statements: [(statement: String, parameters: [String?])] = []

        // Check for key rename
        if let keyChange = change.cellChanges.first(where: { $0.columnName == "Key" }),
           let newKey = keyChange.newValue, newKey != key {
            let renameCmd = "RENAME \(escapeArgument(key)) \(escapeArgument(newKey))"
            statements.append((statement: renameCmd, parameters: []))
        }

        let effectiveKey: String = {
            if let keyChange = change.cellChanges.first(where: { $0.columnName == "Key" }),
               let newKey = keyChange.newValue {
                return newKey
            }
            return key
        }()

        // Determine the Redis type from the original row data
        let redisType: String? = {
            guard let ti = typeColumnIndex,
                  let originalRow = change.originalRow,
                  ti < originalRow.count else {
                return nil
            }
            return originalRow[ti]
        }()

        for cellChange in change.cellChanges {
            switch cellChange.columnName {
            case "Key":
                continue // Already handled above
            case "Value":
                if let newValue = cellChange.newValue {
                    let typeLower = redisType?.lowercased() ?? "string"
                    if typeLower != "string" {
                        // Non-string types show a preview; blindly SET would destroy the data structure
                        Self.logger.warning(
                            "Skipping Value update for \(typeLower) key '\(effectiveKey)' - use query editor"
                        )
                        continue
                    }
                    let cmd = "SET \(escapeArgument(effectiveKey)) \(escapeArgument(newValue))"
                    statements.append((statement: cmd, parameters: []))
                }
            case "TTL":
                if let ttlStr = cellChange.newValue, let ttlSeconds = Int(ttlStr), ttlSeconds > 0 {
                    let cmd = "EXPIRE \(escapeArgument(effectiveKey)) \(ttlSeconds)"
                    statements.append((statement: cmd, parameters: []))
                } else if cellChange.newValue == nil || cellChange.newValue == "-1" {
                    let cmd = "PERSIST \(escapeArgument(effectiveKey))"
                    statements.append((statement: cmd, parameters: []))
                }
            default:
                break
            }
        }

        return statements
    }

    // MARK: - Helpers

    /// Extract the key value from a PluginRowChange's original row
    private func extractKey(from change: PluginRowChange) -> String? {
        guard let keyIndex = keyColumnIndex,
              let originalRow = change.originalRow,
              keyIndex < originalRow.count else {
            return nil
        }
        return originalRow[keyIndex]
    }

    /// Escape a Redis argument for safe embedding in a command string.
    /// Wraps in double quotes if the value contains whitespace or special characters.
    /// Ensures special characters round-trip correctly through the tokenizer.
    private func escapeArgument(_ value: String) -> String {
        let needsQuoting = value.isEmpty || value.contains(where: {
            $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" || $0 == "\n" || $0 == "\r" || $0 == "\t"
        })
        if needsQuoting {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        }
        return value
    }
}

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
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        var statements: [(statement: String, parameters: [PluginCellValue])] = []
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

        if !deleteKeys.isEmpty {
            let keyList = deleteKeys.map { RedisArgumentCodec.quote($0) }.joined(separator: " ")
            let cmd = "DEL \(keyList)"
            statements.append((statement: cmd, parameters: []))
        }

        return statements
    }

    // MARK: - INSERT

    private func generateInsert(
        for change: PluginRowChange,
        insertedRowData: [Int: [PluginCellValue]]
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        var statements: [(statement: String, parameters: [PluginCellValue])] = []

        var key: String?
        var value: String?
        var type: String?
        var ttl: Int?

        if let values = insertedRowData[change.rowIndex] {
            if let ki = keyColumnIndex, ki < values.count {
                key = values[ki].asText
            }
            if let ti = typeColumnIndex, ti < values.count {
                type = values[ti].asText
            }
            if let vi = valueColumnIndex, vi < values.count {
                value = Self.encodedArgument(values[vi])
            }
            if let ttli = ttlColumnIndex, ttli < values.count, let ttlStr = values[ttli].asText {
                ttl = Int(ttlStr)
            }
        } else {
            for cellChange in change.cellChanges {
                switch cellChange.columnName {
                case "Key": key = cellChange.newValue.asText
                case "Type": type = cellChange.newValue.asText
                case "Value": value = Self.encodedArgument(cellChange.newValue)
                case "TTL":
                    if let ttlStr = cellChange.newValue.asText { ttl = Int(ttlStr) }
                default: break
                }
            }
        }

        guard let k = key, !k.isEmpty else {
            Self.logger.warning("Skipping INSERT for namespace '\(self.namespaceName)' - no key")
            return []
        }

        let v = value ?? RedisArgumentCodec.quote("")
        let cmd = generateInsertCommand(key: k, encodedValue: v, type: type?.lowercased())
        statements.append((statement: cmd, parameters: []))

        if let ttlSeconds = ttl, ttlSeconds > 0 {
            let expireCmd = "EXPIRE \(RedisArgumentCodec.quote(k)) \(ttlSeconds)"
            statements.append((statement: expireCmd, parameters: []))
        }

        return statements
    }

    /// Generate the appropriate Redis command based on the data type
    private func generateInsertCommand(key: String, encodedValue: String, type: String?) -> String {
        let quotedKey = RedisArgumentCodec.quote(key)
        switch type {
        case "hash":
            if let fields = Self.hashFields(fromEncoded: encodedValue) {
                return fields.reduce("HSET \(quotedKey)") { command, field in
                    command + " \(RedisArgumentCodec.quote(field.name)) \(RedisArgumentCodec.quote(field.value))"
                }
            }
            return "HSET \(quotedKey) value \(encodedValue)"
        case "list":
            return "RPUSH \(quotedKey) \(encodedValue)"
        case "set":
            return "SADD \(quotedKey) \(encodedValue)"
        case "zset":
            return "ZADD \(quotedKey) 0 \(encodedValue)"
        default:
            return "SET \(quotedKey) \(encodedValue)"
        }
    }

    private static func hashFields(fromEncoded encoded: String) -> [(name: String, value: String)]? {
        guard let decoded = RedisArgumentCodec.split(encoded)?.first,
              let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else {
            return nil
        }
        return json
            .map { (name: $0.key, value: String(describing: $0.value)) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - UPDATE

    private func generateUpdate(for change: PluginRowChange) -> [(statement: String, parameters: [PluginCellValue])] {
        guard !change.cellChanges.isEmpty else { return [] }

        guard let key = extractKey(from: change) else {
            Self.logger.warning("Skipping UPDATE for namespace '\(self.namespaceName)' - no key value")
            return []
        }

        var statements: [(statement: String, parameters: [PluginCellValue])] = []

        if let keyChange = change.cellChanges.first(where: { $0.columnName == "Key" }),
           let newKey = keyChange.newValue.asText, newKey != key {
            let renameCmd = "RENAME \(RedisArgumentCodec.quote(key)) \(RedisArgumentCodec.quote(newKey))"
            statements.append((statement: renameCmd, parameters: []))
        }

        let effectiveKey: String = {
            if let keyChange = change.cellChanges.first(where: { $0.columnName == "Key" }),
               let newKey = keyChange.newValue.asText {
                return newKey
            }
            return key
        }()

        let redisType: String? = {
            guard let ti = typeColumnIndex,
                  let originalRow = change.originalRow,
                  ti < originalRow.count else {
                return nil
            }
            return originalRow[ti].asText
        }()

        for cellChange in change.cellChanges {
            switch cellChange.columnName {
            case "Key":
                continue // Already handled above
            case "Value":
                guard let encodedValue = Self.encodedArgument(cellChange.newValue) else { continue }
                let typeLower = redisType?.lowercased() ?? "string"
                if typeLower != "string" {
                    // Non-string types show a preview; blindly SET would destroy the data structure
                    Self.logger.warning(
                        "Skipping Value update for \(typeLower) key '\(effectiveKey)' - use query editor"
                    )
                    continue
                }
                let cmd = "SET \(RedisArgumentCodec.quote(effectiveKey)) \(encodedValue)"
                statements.append((statement: cmd, parameters: []))
            case "TTL":
                if let ttlStr = cellChange.newValue.asText, let ttlSeconds = Int(ttlStr), ttlSeconds > 0 {
                    let cmd = "EXPIRE \(RedisArgumentCodec.quote(effectiveKey)) \(ttlSeconds)"
                    statements.append((statement: cmd, parameters: []))
                } else if cellChange.newValue.isNull || cellChange.newValue.asText == "-1" {
                    let cmd = "PERSIST \(RedisArgumentCodec.quote(effectiveKey))"
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
        return originalRow[keyIndex].asText
    }

    /// Render a cell as one Redis command argument, keeping binary values byte exact.
    private static func encodedArgument(_ value: PluginCellValue) -> String? {
        switch value {
        case .null: return nil
        case .text(let text): return RedisArgumentCodec.quote(text)
        case .bytes(let bytes): return RedisArgumentCodec.quote(bytes)
        }
    }
}

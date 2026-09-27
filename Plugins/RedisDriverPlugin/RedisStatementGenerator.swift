//
//  RedisStatementGenerator.swift
//  RedisDriverPlugin
//
//  Generates Redis commands from tracked cell changes (edit tracking).
//  Plugin-local version using PluginRowChange instead of Core types.
//

import Foundation
import TableProPluginKit

/// How the grid's deleted keys become `DEL` statements.
enum RedisDeleteBatching: Sendable {
    /// One `DEL` for every key, which a server holding the whole keyspace applies all at once.
    case singleCommand
    /// One `DEL` per hash slot. A cluster splits a `DEL` by slot anyway and one slot can refuse
    /// after another ran, while a single-slot `DEL` is checked against every key before it runs,
    /// so each statement is all or nothing and a save can say how many of them went through.
    case perHashSlot
}

struct RedisStatementGenerator {
    let namespaceName: String
    let columns: [String]
    var deleteBatching: RedisDeleteBatching = .singleCommand

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

    private static let insertableTypes: Set<String> = ["string", "hash", "list", "set", "zset"]

    // MARK: - Public API

    /// The commands that write the grid's changes, each naming the change it writes. A change
    /// carrying a value these commands cannot express is refused whole, because writing the rest
    /// of it would let the save succeed and clear the value it left out.
    func generateRowWrites(
        from changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite] {
        var writes: [PluginRowWrite] = []
        var deletions: [(key: String, rowIndex: Int)] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                writes += try insertCommands(for: change, insertedRowData: insertedRowData)
                    .map { PluginRowWrite(statement: $0, rowIndices: [change.rowIndex]) }

            case .update:
                writes += try updateCommands(for: change)
                    .map { PluginRowWrite(statement: $0, rowIndices: [change.rowIndex]) }

            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                guard let key = extractKey(from: change) else {
                    throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.unaddressableKeyReason)
                }
                deletions.append((key: key, rowIndex: change.rowIndex))
            }
        }

        return writes + deleteWrites(for: deletions)
    }

    private func deleteWrites(for deletions: [(key: String, rowIndex: Int)]) -> [PluginRowWrite] {
        guard !deletions.isEmpty else { return [] }
        let batches: [[(key: String, rowIndex: Int)]]
        switch deleteBatching {
        case .singleCommand: batches = [deletions]
        case .perHashSlot: batches = RedisKeySlot.groupedBySlot(deletions) { $0.key }
        }
        return batches.map { batch in
            let keyList = batch.map { RedisArgumentCodec.quote($0.key) }.joined(separator: " ")
            return PluginRowWrite(statement: "DEL \(keyList)", rowIndices: batch.map { $0.rowIndex })
        }
    }

    // MARK: - INSERT

    private func insertCommands(
        for change: PluginRowChange,
        insertedRowData: [Int: [PluginCellValue]]
    ) throws -> [String] {
        var key: String?
        var value: String?
        var type: String?
        var ttlText: String?

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
            if let ttli = ttlColumnIndex, ttli < values.count {
                ttlText = values[ttli].asText
            }
        } else {
            for cellChange in change.cellChanges {
                switch cellChange.columnName {
                case "Key": key = cellChange.newValue.asText
                case "Type": type = cellChange.newValue.asText
                case "Value": value = Self.encodedArgument(cellChange.newValue)
                case "TTL": ttlText = cellChange.newValue.asText
                default: break
                }
            }
        }

        guard let k = key, !k.isEmpty else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(localized: "A new key needs a name."))
        }

        let typeName = type?.lowercased() ?? "string"
        guard typeName.isEmpty || Self.insertableTypes.contains(typeName) else {
            throw PluginRowWriteRefusal(
                rowIndex: change.rowIndex,
                reason: String(
                    format: String(localized: "A %@ key cannot be added from the grid. Add it with a command in the query editor."),
                    typeName
                )
            )
        }

        var ttl: Int?
        if let ttlText {
            guard let seconds = Int(ttlText), seconds >= 0 || seconds == -1 else {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.invalidTTLReason)
            }
            ttl = seconds
        }

        var commands = [generateInsertCommand(key: k, encodedValue: value ?? RedisArgumentCodec.quote(""), type: typeName)]
        if let ttlSeconds = ttl, ttlSeconds > 0 {
            commands.append("EXPIRE \(RedisArgumentCodec.quote(k)) \(ttlSeconds)")
        }
        return commands
    }

    /// Generate the appropriate Redis command based on the data type
    private func generateInsertCommand(key: String, encodedValue: String, type: String) -> String {
        let quotedKey = RedisArgumentCodec.quote(key)
        switch type {
        case "hash":
            if let fields = Self.hashFields(fromEncoded: encodedValue) {
                return fields.reduce(into: "HSET \(quotedKey)") { command, field in
                    command += " \(RedisArgumentCodec.quote(field.name)) \(RedisArgumentCodec.quote(field.value))"
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

    private func updateCommands(for change: PluginRowChange) throws -> [String] {
        guard !change.cellChanges.isEmpty else { return [] }

        guard let key = extractKey(from: change) else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.unaddressableKeyReason)
        }

        var commands: [String] = []
        var effectiveKey = key

        if let keyChange = change.cellChanges.first(where: { $0.columnName == "Key" }) {
            guard let newKey = keyChange.newValue.asText else {
                throw PluginRowWriteRefusal(
                    rowIndex: change.rowIndex, reason: String(localized: "A key can only be renamed to text.")
                )
            }
            if newKey != key {
                commands.append("RENAME \(RedisArgumentCodec.quote(key)) \(RedisArgumentCodec.quote(newKey))")
            }
            effectiveKey = newKey
        }

        for cellChange in change.cellChanges {
            switch cellChange.columnName {
            case "Key":
                continue
            case "Value":
                commands.append(try valueCommand(setting: cellChange.newValue, of: change, key: effectiveKey))
            case "TTL":
                commands.append(try ttlCommand(setting: cellChange.newValue, of: change, key: effectiveKey))
            default:
                throw PluginRowWriteRefusal(
                    rowIndex: change.rowIndex,
                    reason: String(format: String(localized: "'%@' cannot be changed from the grid."), cellChange.columnName)
                )
            }
        }

        return commands
    }

    /// Only a string's value is the whole of what the grid shows. A collection shows a preview,
    /// and a `SET` over it would replace the structure with that text.
    private func valueCommand(setting newValue: PluginCellValue, of change: PluginRowChange, key: String) throws -> String {
        guard let encodedValue = Self.encodedArgument(newValue) else {
            throw PluginRowWriteRefusal(
                rowIndex: change.rowIndex,
                reason: String(localized: "Redis cannot store NULL as a value. Enter an empty value instead.")
            )
        }
        guard let typeName = valueWriteType(of: change) else {
            throw PluginRowWriteRefusal(
                rowIndex: change.rowIndex,
                reason: String(localized: "The key's type is unknown, so its value cannot be written safely.")
            )
        }
        guard typeName == "string" else {
            throw PluginRowWriteRefusal(
                rowIndex: change.rowIndex,
                reason: String(
                    format: String(localized: "The value of a %@ key cannot be edited in the grid. Change it with a command in the query editor."),
                    typeName
                )
            )
        }
        return "SET \(RedisArgumentCodec.quote(key)) \(encodedValue)"
    }

    private func ttlCommand(setting newValue: PluginCellValue, of change: PluginRowChange, key: String) throws -> String {
        if newValue.isNull || newValue.asText == "-1" {
            return "PERSIST \(RedisArgumentCodec.quote(key))"
        }
        guard let text = newValue.asText, let seconds = Int(text), seconds > 0 else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.invalidTTLReason)
        }
        return "EXPIRE \(RedisArgumentCodec.quote(key)) \(seconds)"
    }

    // MARK: - Refusals

    private static var unaddressableKeyReason: String {
        String(localized: "This key's name is not text, so it cannot be addressed from the grid.")
    }

    private static var invalidTTLReason: String {
        String(localized: "TTL has to be a whole number of seconds above 0, or -1 or NULL for no expiry.")
    }

    // MARK: - Helpers

    /// A grid with no Type column holds strings. One with a Type column holds whatever the server
    /// said, and a Type cell the server would not fill leaves nothing safe to write: `SET` over a
    /// hash replaces the hash.
    private func valueWriteType(of change: PluginRowChange) -> String? {
        guard let typeIndex = typeColumnIndex else { return "string" }
        guard let originalRow = change.originalRow, typeIndex < originalRow.count else { return nil }
        return originalRow[typeIndex].asText?.lowercased()
    }

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

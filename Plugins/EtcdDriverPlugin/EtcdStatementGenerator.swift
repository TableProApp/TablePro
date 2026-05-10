//
//  EtcdStatementGenerator.swift
//  EtcdDriverPlugin
//
//  Generates etcdctl commands from tracked cell changes.
//

import Foundation
import os
import TableProPluginKit

struct EtcdStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "EtcdStatementGenerator")

    let prefix: String
    let columns: [String]

    var keyColumnIndex: Int? { columns.firstIndex(of: "Key") }
    private var valueColumnIndex: Int? { columns.firstIndex(of: "Value") }
    private var leaseColumnIndex: Int? { columns.firstIndex(of: "Lease") }

    func generateStatements(
        from changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        var statements: [(statement: String, parameters: [PluginCellValue])] = []

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
                    statements.append((statement: "del \(escapeArgument(key))", parameters: []))
                }
            }
        }

        return statements
    }

    private func generateInsert(
        for change: PluginRowChange,
        insertedRowData: [Int: [PluginCellValue]]
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        var key: String?
        var value: String?
        var leaseId: String?

        if let values = insertedRowData[change.rowIndex] {
            if let ki = keyColumnIndex, ki < values.count { key = values[ki].asText }
            if let vi = valueColumnIndex, vi < values.count { value = values[vi].asText }
            if let li = leaseColumnIndex, li < values.count { leaseId = values[li].asText }
        } else {
            for cellChange in change.cellChanges {
                switch cellChange.columnName {
                case "Key": key = cellChange.newValue.asText
                case "Value": value = cellChange.newValue.asText
                case "Lease": leaseId = cellChange.newValue.asText
                default: break
                }
            }
        }

        guard let k = key, !k.isEmpty else {
            Self.logger.warning("Skipping INSERT - no key provided")
            return []
        }

        // Prepend the current browse prefix if the key doesn't already include it
        let fullKey: String
        if !prefix.isEmpty && !k.hasPrefix("/") {
            fullKey = prefix + k
        } else {
            fullKey = k
        }
        let v = value ?? ""
        var cmd = "put \(escapeArgument(fullKey)) \(escapeArgument(v))"
        if let lease = leaseId, !lease.isEmpty, lease != "0" {
            cmd += " --lease=\(lease)"
        }

        return [(statement: cmd, parameters: [])]
    }

    private func generateUpdate(
        for change: PluginRowChange
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        guard !change.cellChanges.isEmpty else { return [] }
        guard let originalKey = extractKey(from: change) else {
            Self.logger.warning("Skipping UPDATE - no original key")
            return []
        }

        var statements: [(statement: String, parameters: [PluginCellValue])] = []

        let keyChange = change.cellChanges.first { $0.columnName == "Key" }
        let newKey = keyChange?.newValue.asText ?? originalKey

        guard !newKey.isEmpty else {
            Self.logger.warning("Skipping UPDATE - empty key")
            return []
        }

        let shouldDeleteOriginalKey = newKey != originalKey
        let valueChange = change.cellChanges.first { $0.columnName == "Value" }
        let leaseChange = change.cellChanges.first { $0.columnName == "Lease" }

        if valueChange != nil || newKey != originalKey {
            let newValue = valueChange?.newValue.asText ?? extractOriginalValue(from: change) ?? ""
            var cmd = "put \(escapeArgument(newKey)) \(escapeArgument(newValue))"
            if let lease = leaseChange?.newValue.asText, !lease.isEmpty, lease != "0" {
                cmd += " --lease=\(lease)"
            }
            statements.append((statement: cmd, parameters: []))
            if shouldDeleteOriginalKey {
                statements.append((statement: "del \(escapeArgument(originalKey))", parameters: []))
            }
        } else if let lease = leaseChange?.newValue.asText {
            let currentValue = extractOriginalValue(from: change) ?? ""
            var cmd = "put \(escapeArgument(newKey)) \(escapeArgument(currentValue))"
            if !lease.isEmpty && lease != "0" {
                cmd += " --lease=\(lease)"
            }
            statements.append((statement: cmd, parameters: []))
        }

        return statements
    }

    // MARK: - Helpers

    private func extractKey(from change: PluginRowChange) -> String? {
        guard let keyIndex = keyColumnIndex,
              let originalRow = change.originalRow,
              keyIndex < originalRow.count else { return nil }
        return originalRow[keyIndex].asText
    }

    private func extractOriginalValue(from change: PluginRowChange) -> String? {
        guard let valueIndex = valueColumnIndex,
              let originalRow = change.originalRow,
              valueIndex < originalRow.count else { return nil }
        return originalRow[valueIndex].asText
    }

    private func escapeArgument(_ value: String) -> String {
        let needsQuoting = value.isEmpty || value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
        if needsQuoting {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "\"\(escaped)\""
        }
        return value
    }
}

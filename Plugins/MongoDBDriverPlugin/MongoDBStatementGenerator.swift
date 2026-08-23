//
//  MongoDBStatementGenerator.swift
//  MongoDBDriverPlugin
//
//  Generates MongoDB shell commands (insertOne, replaceOne, deleteOne) from tracked changes.
//  Plugin-local version using PluginRowChange instead of Core types.
//

import Foundation
import os
import TableProNumberFormatting
import TableProPluginKit

struct MongoDBStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MongoDBStatementGenerator")

    let collectionName: String
    let columns: [String]
    var columnKinds: [String: BsonValueKind] = [:]

    /// Collection accessor using bracket notation for safety with dotted names
    private var collectionAccessor: String {
        "db[\"\(escapeJsonString(collectionName))\"]"
    }

    /// Index of "_id" field in the columns array (used as primary key equivalent)
    var idColumnIndex: Int? {
        columns.firstIndex(of: "_id")
    }

    // MARK: - Public API

    /// Generate MongoDB shell statements from changes
    func generateStatements(
        from changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        var statements: [(statement: String, parameters: [PluginCellValue])] = []
        var deleteChanges: [PluginRowChange] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                if let stmt = generateInsert(for: change, insertedRowData: insertedRowData) {
                    statements.append(stmt)
                }
            case .update:
                if let stmt = generateUpdate(for: change) {
                    statements.append(stmt)
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                deleteChanges.append(change)
            }
        }

        // Batch deletes into a single deleteMany when possible
        if let bulkDelete = generateBulkDelete(from: deleteChanges) {
            statements.append(bulkDelete)
        } else {
            for change in deleteChanges {
                if let stmt = generateDelete(for: change) {
                    statements.append(stmt)
                }
            }
        }

        return statements
    }

    // MARK: - INSERT

    private func generateInsert(
        for change: PluginRowChange,
        insertedRowData: [Int: [PluginCellValue]]
    ) -> (statement: String, parameters: [PluginCellValue])? {
        var doc: [String: String] = [:]

        if let values = insertedRowData[change.rowIndex] {
            for (index, value) in values.enumerated() {
                guard index < columns.count else { continue }
                let column = columns[index]
                // Skip _id for inserts (let MongoDB auto-generate)
                if column == "_id" { continue }
                // Skip DEFAULT sentinel
                let textValue = value.asText
                if textValue == "__DEFAULT__" { continue }
                if let val = textValue {
                    doc[column] = val
                }
            }
        } else {
            // Fallback: use cellChanges
            for cellChange in change.cellChanges {
                if cellChange.columnName == "_id" { continue }
                let newText = cellChange.newValue.asText
                if newText == "__DEFAULT__" { continue }
                if let val = newText {
                    doc[cellChange.columnName] = val
                }
            }
        }

        guard !doc.isEmpty else { return nil }

        guard let docJson = serializeDocument(doc) else { return nil }
        let shell = "\(collectionAccessor).insertOne(\(docJson))"
        return (statement: shell, parameters: [])
    }

    // MARK: - UPDATE (updateOne with $set/$unset)

    private func generateUpdate(for change: PluginRowChange) -> (statement: String, parameters: [PluginCellValue])? {
        guard !change.cellChanges.isEmpty else { return nil }

        guard let idIndex = idColumnIndex,
              let originalRow = change.originalRow,
              idIndex < originalRow.count,
              let idValue = originalRow[idIndex].asText else {
            Self.logger.warning("Skipping UPDATE for collection '\(self.collectionName)' - no _id value")
            return nil
        }

        var setDoc: [String: String] = [:]
        var unsetFields: [String] = []

        for cellChange in change.cellChanges {
            if cellChange.columnName == "_id" { continue }
            if let val = cellChange.newValue.asText {
                setDoc[cellChange.columnName] = val
            } else {
                unsetFields.append(cellChange.columnName)
            }
        }

        guard !setDoc.isEmpty || !unsetFields.isEmpty else { return nil }

        let filterJson = buildIdFilter(idValue)

        // Build update document with $set and/or $unset
        var updateParts: [String] = []
        if !setDoc.isEmpty {
            guard let setJson = serializeDocument(setDoc) else { return nil }
            updateParts.append("\"$set\": \(setJson)")
        }
        if !unsetFields.isEmpty {
            let unsetDoc = unsetFields.sorted().map { "\"\(escapeJsonString($0))\": \"\"" }.joined(separator: ", ")
            updateParts.append("\"$unset\": {\(unsetDoc)}")
        }

        let updateJson = "{\(updateParts.joined(separator: ", "))}"
        let shell = "\(collectionAccessor).updateOne(\(filterJson), \(updateJson))"
        return (statement: shell, parameters: [])
    }

    // MARK: - DELETE MANY

    /// Batch multiple deletes into a single deleteMany with $in when all rows have _id
    private func generateBulkDelete(from changes: [PluginRowChange]) -> (statement: String, parameters: [PluginCellValue])? {
        guard changes.count > 1, let idIndex = idColumnIndex else { return nil }

        var idValues: [String] = []
        for change in changes {
            guard let originalRow = change.originalRow,
                  idIndex < originalRow.count,
                  let idValue = originalRow[idIndex].asText else {
                return nil
            }
            idValues.append(idValueJson(idValue))
        }

        let inList = idValues.joined(separator: ", ")
        let shell = "\(collectionAccessor).deleteMany({\"_id\": {\"$in\": [\(inList)]}})"
        return (statement: shell, parameters: [])
    }

    // MARK: - DELETE

    private func generateDelete(for change: PluginRowChange) -> (statement: String, parameters: [PluginCellValue])? {
        guard let originalRow = change.originalRow,
              let idIndex = idColumnIndex,
              idIndex < originalRow.count,
              let idValue = originalRow[idIndex].asText else {
            Self.logger.warning("Skipping DELETE for collection '\(self.collectionName)' - no _id value")
            return nil
        }

        let filterJson = buildIdFilter(idValue)
        let shell = "\(collectionAccessor).deleteOne(\(filterJson))"
        return (statement: shell, parameters: [])
    }

    // MARK: - Helpers

    /// Build a filter document for an _id value (Extended JSON for driver execution).
    private func buildIdFilter(_ idValue: String) -> String {
        "{\"_id\": \(idValueJson(idValue))}"
    }

    private func idValueJson(_ idValue: String) -> String {
        if let binary = MongoDBUuidCodec.extendedJsonFromWrapper(idValue) {
            return binary
        }
        if isObjectIdString(idValue) {
            return "{\"$oid\": \"\(idValue)\"}"
        }
        if Int64(idValue) != nil {
            return idValue
        }
        return "\"\(escapeJsonString(idValue))\""
    }

    /// Check if a string looks like a MongoDB ObjectId (24 hex characters)
    private func isObjectIdString(_ value: String) -> Bool {
        let nsValue = value as NSString
        return nsValue.length == 24 && value.allSatisfy { $0.isHexDigit }
    }

    /// Serialize a [String: String] dictionary to JSON-like format
    private func serializeDocument(_ doc: [String: String]) -> String? {
        var entries: [String] = []
        for (key, value) in doc.sorted(by: { $0.key < $1.key }) {
            guard !JSONTruncation.isIncompleteStructure(value) else {
                Self.logger.warning(
                    "Skipping write for '\(self.collectionName).\(key)' - the shown value is truncated"
                )
                return nil
            }
            entries.append("\"\(escapeJsonString(key))\": \(jsonValue(for: value, kind: columnKinds[key]))")
        }
        return "{\(entries.joined(separator: ", "))}"
    }

    /// Convert a string value to its JSON representation (auto-detect type)
    private func jsonValue(for value: String, kind: BsonValueKind? = nil) -> String {
        if value == "true" || value == "false" {
            return value
        }
        if value == "null" {
            return "null"
        }
        if kind == .decimal128, NumberText.isJSONNumberLiteral(value) {
            return "{\"$numberDecimal\": \"\(escapeJsonString(value))\"}"
        }
        if MongoDBJsonNumber.isValid(value) {
            return typedNumberJson(value, kind: kind)
        }
        if let binary = MongoDBUuidCodec.extendedJsonFromWrapper(value) {
            return binary
        }
        // JSON object or array
        if (value.hasPrefix("{") && value.hasSuffix("}")) ||
            (value.hasPrefix("[") && value.hasSuffix("]")) {
            return value
        }
        return "\"\(escapeJsonString(value))\""
    }

    /// A bare JSON number is stored as int32 or double, which silently retypes a column that
    /// holds int64 or decimal128. Extended JSON is the only way to keep the original type.
    private func typedNumberJson(_ value: String, kind: BsonValueKind?) -> String {
        switch kind {
        case .decimal128:
            return "{\"$numberDecimal\": \"\(escapeJsonString(value))\"}"
        case .int64:
            guard Int64(value) != nil else { return value }
            return "{\"$numberLong\": \"\(escapeJsonString(value))\"}"
        case .double:
            guard let parsed = Double(value), parsed.isFinite else { return value }
            return "{\"$numberDouble\": \"\(escapeJsonString(value))\"}"
        default:
            return value
        }
    }

    /// Escape special characters for JSON strings (handles Unicode control chars U+0000-U+001F)
    private func escapeJsonString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity((value as NSString).length)
        for char in value {
            switch char {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if let ascii = char.asciiValue, ascii < 0x20 {
                    result += String(format: "\\u%04X", ascii)
                } else {
                    result.append(char)
                }
            }
        }
        return result
    }
}

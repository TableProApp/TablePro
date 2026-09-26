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
    /// Kinds the collection's validator declares. The server rejects any other type for these
    /// fields, so they outrank what the sampled documents happen to hold.
    var declaredKinds: [String: BsonValueKind] = [:]
    /// The kind every sampled `_id` shares, or nil when they differ. An `_id` filter has to carry the
    /// row's own type, and a majority kind would quote an ObjectId in a mostly-string collection and
    /// match nothing.
    var identityKind: BsonValueKind?

    private var collectionAccessor: String {
        MongoCollectionAccessor.expression(for: collectionName)
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

    // MARK: - Restore

    /// Puts a deleted document back with the `_id` it had.
    ///
    /// `generateInsert` drops `_id` so a row the user just added gets a server-generated one.
    /// Undoing a delete is the opposite requirement: a new `_id` is a different document, and
    /// anything that referenced the old one still points at nothing.
    func generateRestore(rows: [[PluginCellValue]]) -> [(statement: String, parameters: [PluginCellValue])]? {
        guard let idIndex = idColumnIndex else { return nil }

        var statements: [(statement: String, parameters: [PluginCellValue])] = []
        for row in rows {
            guard idIndex < row.count, let idValue = row[idIndex].asText else { return nil }

            var doc: [String: String] = [:]
            for (index, value) in row.enumerated() where index != idIndex {
                guard index < columns.count else { continue }
                /// A binary field has no text form here, and writing the document without it
                /// restores a document that is missing a field. Refuse the whole restore instead,
                /// which the host reports rather than passing off as a success.
                if value.asBytes != nil { return nil }
                guard let text = value.asText else { continue }
                if text == "__DEFAULT__" { continue }
                doc[columns[index]] = text
            }

            guard var docJson = serializeDocument(doc) else { return nil }
            let idEntry = "\"_id\": \(idValueJson(idValue))"
            docJson = docJson == "{}" ? "{\(idEntry)}" : "{\(idEntry), " + String(docJson.dropFirst())
            statements.append((statement: "\(collectionAccessor).insertOne(\(docJson))", parameters: []))
        }
        return statements
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

    /// An `_id` is matched by value and type together, so a string `_id` of `1001` written as a
    /// number matches no document. The column's own kind decides when it is known; the text's
    /// shape is only the fallback.
    private func idValueJson(_ idValue: String) -> String {
        if let binary = MongoDBUuidCodec.extendedJsonFromWrapper(idValue) {
            return binary
        }
        let idKind = declaredKinds["_id"] ?? identityKind
        switch idKind {
        case .string:
            return "\"\(escapeJsonString(idValue))\""
        case .objectId, .int32, .int64, .double, .decimal128, .date:
            if let typed = typedJson(idValue, kind: idKind) { return typed }
        case .boolean:
            if idValue == "true" || idValue == "false" { return idValue }
        default:
            break
        }
        if isObjectIdString(idValue) {
            return "{\"$oid\": \"\(idValue)\"}"
        }
        if Int64(idValue) != nil {
            return integerJson(idValue)
        }
        return "\"\(escapeJsonString(idValue))\""
    }

    private func kind(of field: String) -> BsonValueKind? {
        declaredKinds[field] ?? columnKinds[field]
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
            entries.append("\"\(escapeJsonString(key))\": \(jsonValue(for: value, field: key))")
        }
        return "{\(entries.joined(separator: ", "))}"
    }

    /// A cell's text as the value it stands for, in the field's type when that type is known.
    ///
    /// The statement is JavaScript the shell evaluates, so text is only ever pasted in when it is
    /// strict JSON. A stored string that merely starts with `[` and ends with `]` would otherwise run
    /// as code the moment its row is duplicated or its delete is undone.
    private func jsonValue(for value: String, field: String) -> String {
        if declaredKinds[field] == .string {
            return "\"\(escapeJsonString(value))\""
        }
        if value == "true" || value == "false" || value == "null" {
            return value
        }
        if let typed = typedJson(value, kind: kind(of: field)) {
            return typed
        }
        if MongoDBJsonNumber.isValid(value) {
            return Int64(value) != nil ? integerJson(value) : value
        }
        if let binary = MongoDBUuidCodec.extendedJsonFromWrapper(value) {
            return binary
        }
        if isStrictJsonContainer(value) {
            return value
        }
        return "\"\(escapeJsonString(value))\""
    }

    /// A bare JSON number is stored as int32 or double, which silently retypes a column that
    /// holds int64 or decimal128, and a date or an ObjectId written as its text is a string.
    /// Extended JSON is the only way to keep the original type.
    private func typedJson(_ value: String, kind: BsonValueKind?) -> String? {
        switch kind {
        case .date:
            return MongoDBFilterValue.writableDateJson(value)
        case .objectId:
            return MongoDBFilterValue.objectIdJson(value)
        case .decimal128:
            guard NumberText.isJSONNumberLiteral(value) else { return nil }
            return "{\"$numberDecimal\": \"\(escapeJsonString(value))\"}"
        case .int64:
            guard Int64(value) != nil else { return nil }
            return "{\"$numberLong\": \"\(escapeJsonString(value))\"}"
        case .double:
            guard MongoDBJsonNumber.isValid(value), let parsed = Double(value), parsed.isFinite else { return nil }
            return "{\"$numberDouble\": \"\(escapeJsonString(value))\"}"
        case .int32:
            guard let parsed = Int32(value) else { return nil }
            return String(parsed)
        default:
            return nil
        }
    }

    /// JavaScript numbers are doubles, so an integer past 2^53 written bare reaches the server
    /// already rounded.
    private func integerJson(_ value: String) -> String {
        guard let parsed = Int64(value), parsed.magnitude > Self.largestExactDouble else { return value }
        return "{\"$numberLong\": \"\(value)\"}"
    }

    private static let largestExactDouble: UInt64 = 1 << 53

    private func isStrictJsonContainer(_ value: String) -> Bool {
        guard (value.hasPrefix("{") && value.hasSuffix("}")) || (value.hasPrefix("[") && value.hasSuffix("]")),
              let data = value.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return false }
        return parsed is [String: Any] || parsed is [Any]
    }

    /// Escape special characters for JSON strings (handles Unicode control chars U+0000-U+001F)
    private func escapeJsonString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity((value as NSString).length)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}

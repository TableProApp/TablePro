//
//  TypesenseStatementGenerator.swift
//  TypesenseDriverPlugin
//
//  Converts tracked cell changes into tagged Typesense REST mutations.
//

import Foundation
import os
import TableProPluginKit

struct TypesenseWriteRequest: Equatable {
    let method: String
    let path: String
    let body: String?
}

struct TypesenseStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TypesenseStatementGenerator")
    static let writeTag = "TYPESENSE_WRITE:"

    let collection: String
    let columns: [String]
    let fields: [String: TypesenseField]

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
                if let statement = generateInsert(for: change, insertedRowData: insertedRowData) {
                    statements.append(statement)
                }
            case .update:
                if let statement = generateUpdate(for: change) {
                    statements.append(statement)
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                if let statement = generateDelete(for: change) {
                    statements.append(statement)
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
        var values: [String: PluginCellValue] = [:]
        if let rowData = insertedRowData[change.rowIndex] {
            for (columnIndex, column) in columns.enumerated() where columnIndex < rowData.count {
                values[column] = rowData[columnIndex]
            }
        } else {
            for cellChange in change.cellChanges {
                values[cellChange.columnName] = cellChange.newValue
            }
        }

        var document: [String: Any] = [:]
        for column in columns {
            guard let text = values[column]?.asText else { continue }
            guard column != TypesenseSchema.idColumn || !text.isEmpty else { continue }
            document[column] = jsonValue(text, for: column)
        }

        guard let body = serialize(document) else { return nil }
        return encode(.init(method: "POST", path: documentsPath, body: body))
    }

    // MARK: - UPDATE

    /// A partial update is a `PATCH` carrying only the changed fields. `id` is the document's
    /// identity and Typesense refuses to rewrite it, so it never joins the payload.
    private func generateUpdate(for change: PluginRowChange) -> (statement: String, parameters: [PluginCellValue])? {
        guard let id = documentId(from: change) else {
            Self.logger.warning("Skipping UPDATE - missing id")
            return nil
        }

        var document: [String: Any] = [:]
        for cellChange in change.cellChanges where cellChange.columnName != TypesenseSchema.idColumn {
            if let text = cellChange.newValue.asText {
                document[cellChange.columnName] = jsonValue(text, for: cellChange.columnName)
            } else {
                document[cellChange.columnName] = NSNull()
            }
        }

        guard !document.isEmpty, let body = serialize(document) else { return nil }
        return encode(.init(method: "PATCH", path: documentPath(id: id), body: body))
    }

    // MARK: - DELETE

    private func generateDelete(for change: PluginRowChange) -> (statement: String, parameters: [PluginCellValue])? {
        guard let id = documentId(from: change) else {
            Self.logger.warning("Skipping DELETE - missing id")
            return nil
        }
        return encode(.init(method: "DELETE", path: documentPath(id: id), body: nil))
    }

    // MARK: - Helpers

    private func documentId(from change: PluginRowChange) -> String? {
        guard let originalRow = change.originalRow,
              let idIndex = columns.firstIndex(of: TypesenseSchema.idColumn),
              idIndex < originalRow.count,
              let id = originalRow[idIndex].asText,
              !id.isEmpty
        else { return nil }
        return id
    }

    private var documentsPath: String {
        "/collections/\(TypesensePathEncoding.segment(collection))/documents"
    }

    private func documentPath(id: String) -> String {
        "\(documentsPath)/\(TypesensePathEncoding.segment(id))"
    }

    private func jsonValue(_ text: String, for column: String) -> Any {
        guard let field = fields[column] else { return text }

        if field.isNumeric, !field.type.hasSuffix("[]") {
            if field.type.hasPrefix("int"), let value = Int(text) { return value }
            if let value = Double(text) { return value }
        }
        if field.isBoolean, !field.type.hasSuffix("[]") {
            let lowered = text.lowercased()
            if lowered == "true" { return true }
            if lowered == "false" { return false }
        }
        if field.type.hasSuffix("[]") || field.isObject,
           let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data),
           parsed is [Any] || parsed is [String: Any] {
            return parsed
        }
        return text
    }

    private func serialize(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func encode(_ request: TypesenseWriteRequest) -> (statement: String, parameters: [PluginCellValue]) {
        (statement: Self.encode(request), parameters: [])
    }

    static func encode(_ request: TypesenseWriteRequest) -> String {
        let method = Data(request.method.utf8).base64EncodedString()
        let path = Data(request.path.utf8).base64EncodedString()
        let body = Data((request.body ?? "").utf8).base64EncodedString()
        return "\(writeTag)\(method):\(path):\(body)"
    }

    static func decode(_ statement: String) -> TypesenseWriteRequest? {
        guard statement.hasPrefix(writeTag) else { return nil }
        let parts = String(statement.dropFirst(writeTag.count)).components(separatedBy: ":")
        guard parts.count >= 3,
              let method = decodeBase64(parts[0]),
              let path = decodeBase64(parts[1])
        else { return nil }
        let body = decodeBase64(parts[2])
        return TypesenseWriteRequest(method: method, path: path, body: (body?.isEmpty ?? true) ? nil : body)
    }

    static func isTaggedStatement(_ statement: String) -> Bool {
        statement.hasPrefix(writeTag)
    }

    private static func decodeBase64(_ string: String) -> String? {
        guard let data = Data(base64Encoded: string) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

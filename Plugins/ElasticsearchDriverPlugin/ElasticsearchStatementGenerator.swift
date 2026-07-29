//
//  ElasticsearchStatementGenerator.swift
//  ElasticsearchDriverPlugin
//
//  Converts tracked cell changes into tagged Elasticsearch REST mutations.
//

import Foundation
import os
import TableProPluginKit

struct ElasticsearchWriteRequest: Equatable {
    let method: String
    let path: String
    let body: String?
}

struct ElasticsearchStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ElasticsearchStatementGenerator")
    static let writeTag = "ELASTICSEARCH_WRITE:"
    private static let refreshQuery = "?refresh=true"

    let index: String
    let columns: [String]
    let columnTypeNames: [String]

    private var metaColumns: Set<String> { Set(ElasticsearchMappingFlattener.metaColumns) }

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
        for column in columns where !metaColumns.contains(column) {
            guard let value = values[column], let text = value.asText else { continue }
            document[column] = jsonValue(text, for: column)
        }

        guard let body = serialize(document) else { return nil }

        let explicitId = values[ElasticsearchMappingFlattener.idColumn]?.asText
        if let id = explicitId, !id.isEmpty {
            return encode(.init(method: "PUT", path: docPath(id: id), body: body))
        }
        return encode(.init(method: "POST", path: "/\(encodedIndex)/_doc\(Self.refreshQuery)", body: body))
    }

    // MARK: - UPDATE

    private func generateUpdate(for change: PluginRowChange) -> (statement: String, parameters: [PluginCellValue])? {
        guard let id = documentId(from: change) else {
            Self.logger.warning("Skipping UPDATE - missing _id")
            return nil
        }

        var doc: [String: Any] = [:]
        for cellChange in change.cellChanges where !metaColumns.contains(cellChange.columnName) {
            if let text = cellChange.newValue.asText {
                doc[cellChange.columnName] = jsonValue(text, for: cellChange.columnName)
            } else {
                doc[cellChange.columnName] = NSNull()
            }
        }

        guard !doc.isEmpty, let body = serialize(["doc": doc]) else { return nil }
        return encode(.init(method: "POST", path: "/\(encodedIndex)/_update/\(encodePathComponent(id))\(Self.refreshQuery)", body: body))
    }

    // MARK: - DELETE

    private func generateDelete(for change: PluginRowChange) -> (statement: String, parameters: [PluginCellValue])? {
        guard let id = documentId(from: change) else {
            Self.logger.warning("Skipping DELETE - missing _id")
            return nil
        }
        return encode(.init(method: "DELETE", path: docPath(id: id), body: nil))
    }

    // MARK: - Helpers

    private func documentId(from change: PluginRowChange) -> String? {
        guard let originalRow = change.originalRow,
              let idIndex = columns.firstIndex(of: ElasticsearchMappingFlattener.idColumn),
              idIndex < originalRow.count,
              let id = originalRow[idIndex].asText,
              !id.isEmpty
        else { return nil }
        return id
    }

    private func docPath(id: String) -> String {
        "/\(encodedIndex)/_doc/\(encodePathComponent(id))\(Self.refreshQuery)"
    }

    private var encodedIndex: String {
        encodePathComponent(index)
    }

    private static let pathComponentAllowed: CharacterSet =
        .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    private static let structuredTypes: Set<String> = ["object", "nested", "flattened", "join"]

    private func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowed) ?? value
    }

    private func jsonValue(_ text: String, for column: String) -> Any {
        let typeName = columns.firstIndex(of: column).flatMap { index in
            index < columnTypeNames.count ? columnTypeNames[index] : nil
        } ?? ""

        if ElasticsearchQueryBuilder.numericTypes.contains(typeName) {
            if let intVal = Int(text) { return intVal }
            if let doubleVal = Double(text) { return doubleVal }
        }
        if typeName == "boolean" {
            let lower = text.lowercased()
            if lower == "true" { return true }
            if lower == "false" { return false }
        }

        if let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            if parsed is [Any] { return parsed }
            if parsed is [String: Any], Self.structuredTypes.contains(typeName) { return parsed }
        }
        return text
    }

    private func serialize(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func encode(_ request: ElasticsearchWriteRequest) -> (statement: String, parameters: [PluginCellValue]) {
        (statement: Self.encode(request), parameters: [])
    }

    static func encode(_ request: ElasticsearchWriteRequest) -> String {
        let b64Method = Data(request.method.utf8).base64EncodedString()
        let b64Path = Data(request.path.utf8).base64EncodedString()
        let b64Body = Data((request.body ?? "").utf8).base64EncodedString()
        return "\(writeTag)\(b64Method):\(b64Path):\(b64Body)"
    }

    static func decode(_ statement: String) -> ElasticsearchWriteRequest? {
        guard statement.hasPrefix(writeTag) else { return nil }
        let parts = String(statement.dropFirst(writeTag.count)).components(separatedBy: ":")
        guard parts.count >= 3,
              let method = decodeBase64(parts[0]),
              let path = decodeBase64(parts[1])
        else { return nil }
        let body = decodeBase64(parts[2])
        return ElasticsearchWriteRequest(method: method, path: path, body: (body?.isEmpty ?? true) ? nil : body)
    }

    static func isTaggedStatement(_ statement: String) -> Bool {
        statement.hasPrefix(writeTag)
    }

    private static func decodeBase64(_ string: String) -> String? {
        guard let data = Data(base64Encoded: string) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

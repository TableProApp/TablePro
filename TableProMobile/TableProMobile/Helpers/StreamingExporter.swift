//
//  StreamingExporter.swift
//  TableProMobile
//

import Foundation
import os
import TableProDatabase
import TableProModels

actor StreamingExporter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "StreamingExporter")

    init() {}

    func exportToFile(
        driver: DatabaseDriver,
        query: String,
        format: ExportFormat,
        tableName: String,
        options: StreamOptions = .default
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TablePro-export-\(UUID().uuidString).\(format.fileExtension)")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var headerWritten = false
        var seenColumns: [String] = []
        var rowIndex = 0

        if case .json = format {
            try handle.write(contentsOf: Data("[\n".utf8))
        }

        do {
            for try await element in driver.executeStreaming(query: query, options: options) {
                switch element {
                case .columns(let cols):
                    seenColumns = cols.map(\.name)
                    if !headerWritten, format != .json {
                        let header = formatHeader(format: format, columns: seenColumns) + "\n"
                        try handle.write(contentsOf: Data(header.utf8))
                        headerWritten = true
                    }
                case .row(let row):
                    let values = row.legacyValues
                    let line = formatRow(
                        format: format,
                        columns: seenColumns,
                        values: values,
                        tableName: tableName,
                        isFirst: rowIndex == 0
                    )
                    try handle.write(contentsOf: Data(line.utf8))
                    rowIndex += 1
                case .rowsAffected, .statusMessage, .truncated:
                    continue
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        if case .json = format {
            try handle.write(contentsOf: Data("\n]\n".utf8))
        }

        Self.logger.info("Streaming export wrote \(rowIndex) rows to \(url.lastPathComponent, privacy: .public)")
        return url
    }

    private func formatHeader(format: ExportFormat, columns: [String]) -> String {
        switch format {
        case .csv:
            return columns.map(escapeCsv).joined(separator: ",")
        case .json:
            return ""
        case .sqlInsert:
            return ""
        }
    }

    private func formatRow(format: ExportFormat, columns: [String], values: [String?], tableName: String, isFirst: Bool) -> String {
        switch format {
        case .csv:
            let cells = columns.indices.map { i in
                escapeCsv(i < values.count ? (values[i] ?? "NULL") : "NULL")
            }
            return cells.joined(separator: ",") + "\n"
        case .json:
            var dict: [String: Any] = [:]
            for (i, name) in columns.enumerated() where i < values.count {
                if let value = values[i] {
                    dict[name] = value
                } else {
                    dict[name] = NSNull()
                }
            }
            let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return (isFirst ? "  " : ",\n  ") + json
        case .sqlInsert:
            let safeTable = tableName.replacingOccurrences(of: "`", with: "``")
            let columnList = columns.map { "`\($0.replacingOccurrences(of: "`", with: "``"))`" }.joined(separator: ", ")
            let valueList = columns.indices.map { i -> String in
                guard i < values.count, let value = values[i] else { return "NULL" }
                let escaped = value.replacingOccurrences(of: "'", with: "''")
                return "'\(escaped)'"
            }.joined(separator: ", ")
            return "INSERT INTO `\(safeTable)` (\(columnList)) VALUES (\(valueList));\n"
        }
    }

    private func escapeCsv(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}

extension ExportFormat {
    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        case .sqlInsert: return "sql"
        }
    }
}

//
//  BigQueryTypeMapper.swift
//  BigQueryDriverPlugin
//
//  Converts BigQuery REST API response rows and schema to flat tabular format.
//

import Foundation
import TableProPluginKit

internal struct BigQueryTypeMapper {
    // MARK: - Row Flattening

    static func flattenRows(from response: BQQueryResponse, schema: BQTableSchema) -> [[String?]] {
        guard let rows = response.rows, let fields = schema.fields else { return [] }
        return rows.map { row in
            flattenRow(cells: row.f ?? [], fields: fields)
        }
    }

    private static func flattenRow(
        cells: [BQQueryResponse.BQCell],
        fields: [BQTableFieldSchema]
    ) -> [String?] {
        var result: [String?] = []
        for (index, field) in fields.enumerated() {
            let cellValue: BQCellValue? = index < cells.count ? cells[index].v : nil
            result.append(convertCellValue(cellValue, field: field))
        }
        return result
    }

    private static func convertCellValue(_ value: BQCellValue?, field: BQTableFieldSchema) -> String? {
        guard let value else { return nil }

        let isRepeated = field.mode?.uppercased() == "REPEATED"

        switch value {
        case .null:
            return nil

        case .string(let str):
            if isRepeated {
                return "[\(str)]"
            }
            return convertScalarString(str, type: field.type)

        case .record(let record):
            if let subFields = field.fields, let cells = record.f {
                let subRow = flattenRow(cells: cells, fields: subFields)
                return structToJson(subRow, fields: subFields)
            }
            return nil

        case .array(let items):
            let converted = items.map { item -> String in
                switch item {
                case .null:
                    return "null"
                case .string(let s):
                    let converted = convertScalarString(s, type: field.type) ?? "null"
                    return jsonQuoteIfNeeded(converted, type: field.type)
                case .record(let record):
                    if let subFields = field.fields, let cells = record.f {
                        let subRow = flattenRow(cells: cells, fields: subFields)
                        return structToJson(subRow, fields: subFields) ?? "null"
                    }
                    return "null"
                case .array:
                    return "[]"
                }
            }
            return "[\(converted.joined(separator: ","))]"
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func convertScalarString(_ str: String, type: String) -> String? {
        switch type.uppercased() {
        case "TIMESTAMP":
            // BigQuery returns timestamps as epoch-seconds strings like "1.617235200E9"
            if let epochSeconds = Double(str) {
                let date = Date(timeIntervalSince1970: epochSeconds)
                return timestampFormatter.string(from: date)
            }
            return str

        case "BYTES":
            return str

        case "BOOLEAN", "BOOL":
            return str.lowercased() == "true" ? "true" : "false"

        case "RANGE":
            return str

        default:
            return str
        }
    }

    private static func jsonQuoteIfNeeded(_ value: String, type: String) -> String {
        let upper = type.uppercased()
        if upper == "INT64" || upper == "FLOAT64" || upper == "NUMERIC" ||
            upper == "BIGNUMERIC" || upper == "BOOLEAN" || upper == "BOOL"
        {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func structToJson(_ row: [String?], fields: [BQTableFieldSchema]) -> String? {
        var pairs: [String] = []
        for (index, field) in fields.enumerated() {
            let value = index < row.count ? row[index] : nil
            let key = "\"\(field.name)\""
            if let value {
                let jsonVal = jsonQuoteIfNeeded(value, type: field.type)
                pairs.append("\(key):\(jsonVal)")
            } else {
                pairs.append("\(key):null")
            }
        }
        return "{\(pairs.joined(separator: ","))}"
    }

    // MARK: - Column Type Names

    static func columnTypeNames(from schema: BQTableSchema) -> [String] {
        guard let fields = schema.fields else { return [] }
        return fields.map { fieldTypeName($0) }
    }

    private static func fieldTypeName(_ field: BQTableFieldSchema) -> String {
        let isRepeated = field.mode?.uppercased() == "REPEATED"

        if field.type.uppercased() == "RANGE" {
            return isRepeated ? "ARRAY<RANGE>" : "RANGE"
        }

        if field.type.uppercased() == "RECORD" || field.type.uppercased() == "STRUCT" {
            let innerFields = field.fields ?? []
            let inner = innerFields.map { "\($0.name) \(fieldTypeName($0))" }.joined(separator: ", ")
            let structType = "STRUCT<\(inner)>"
            return isRepeated ? "ARRAY<\(structType)>" : structType
        }

        return isRepeated ? "ARRAY<\(field.type)>" : field.type
    }

    // MARK: - Column Infos

    static func columnInfos(from fields: [BQTableFieldSchema]) -> [PluginColumnInfo] {
        fields.map { field in
            PluginColumnInfo(
                name: field.name,
                dataType: fieldTypeName(field),
                isNullable: field.mode?.uppercased() != "REQUIRED",
                isPrimaryKey: false,
                comment: field.description
            )
        }
    }
}

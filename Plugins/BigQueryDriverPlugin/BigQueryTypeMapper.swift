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

    static func flattenRows(from response: BQQueryResponse, schema: BQTableSchema) -> [[PluginCellValue]] {
        guard let rows = response.rows, let fields = schema.fields else { return [] }
        return rows.map { row in
            let stringCells = flattenRow(cells: row.f ?? [], fields: fields)
            return stringCells.enumerated().map { index, raw -> PluginCellValue in
                guard let value = raw else { return .null }
                let isBinary = (index < fields.count) && fields[index].type.uppercased() == "BYTES"
                if isBinary, let data = Data(base64Encoded: value) {
                    return .bytes(data)
                }
                return .text(value)
            }
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

        switch value {
        case .null:
            return nil

        case .string(let str):
            return convertScalarString(str, type: field.type)

        case .record, .array:
            return jsonValue(for: value, field: field)?.serialized
        }
    }

    private static func jsonValue(for value: BQCellValue, field: BQTableFieldSchema) -> BQJsonValue? {
        switch value {
        case .null:
            return .null

        case .string(let str):
            guard let scalar = convertScalarString(str, type: field.type) else { return .null }
            return isJsonLiteral(type: field.type) ? .literal(scalar) : .text(scalar)

        case .array(let items):
            return .array(items.map { jsonValue(for: $0, field: field) ?? .null })

        case .record(let record):
            guard let subFields = field.fields else { return nil }
            let members = subFields.enumerated().map { index, subField -> BQJsonValue.Member in
                let cell: BQCellValue? = index < record.f.count ? record.f[index].v : nil
                guard let cell, let json = jsonValue(for: cell, field: subField) else {
                    return BQJsonValue.Member(name: subField.name, value: .null)
                }
                return BQJsonValue.Member(name: subField.name, value: json)
            }
            return .object(members)
        }
    }

    private static func isJsonLiteral(type: String) -> Bool {
        switch type.uppercased() {
        case "INT64", "FLOAT64", "NUMERIC", "BIGNUMERIC", "BOOLEAN", "BOOL":
            return true
        default:
            return false
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

private enum BQJsonValue {
    case null
    case literal(String)
    case text(String)
    case array([BQJsonValue])
    case object([Member])

    struct Member {
        let name: String
        let value: BQJsonValue
    }

    var serialized: String {
        switch self {
        case .null:
            return "null"
        case .literal(let value):
            return value
        case .text(let value):
            return "\"\(BQJsonValue.escaped(value))\""
        case .array(let items):
            return "[\(items.map(\.serialized).joined(separator: ","))]"
        case .object(let members):
            let pairs = members.map { "\"\(BQJsonValue.escaped($0.name))\":\($0.value.serialized)" }
            return "{\(pairs.joined(separator: ","))}"
        }
    }

    private static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity((text as NSString).length)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":
                result.append("\\\"")
            case "\\":
                result.append("\\\\")
            case "\n":
                result.append("\\n")
            case "\r":
                result.append("\\r")
            case "\t":
                result.append("\\t")
            default:
                if scalar.value < 0x20 {
                    result.append(String(format: "\\u%04x", scalar.value))
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}

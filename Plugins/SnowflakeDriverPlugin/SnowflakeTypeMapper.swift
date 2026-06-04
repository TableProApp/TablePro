//
//  SnowflakeTypeMapper.swift
//  SnowflakeDriverPlugin
//
//  Maps Snowflake's internal row metadata types to display type names and
//  decodes JSON cell values into PluginCellValue.
//

import Foundation
import TableProPluginKit

struct SnowflakeColumnMeta: Sendable {
    let name: String
    let internalType: String
    let nullable: Bool
    let precision: Int?
    let scale: Int?
    let length: Int?
}

enum SnowflakeTypeMapper {
    static func displayType(for column: SnowflakeColumnMeta) -> String {
        switch column.internalType.lowercased() {
        case "fixed":
            if let scale = column.scale, scale > 0 {
                let precision = column.precision ?? 38
                return "NUMBER(\(precision),\(scale))"
            }
            return "NUMBER"
        case "real":
            return "FLOAT"
        case "text":
            if let length = column.length, length > 0 {
                return "VARCHAR(\(length))"
            }
            return "VARCHAR"
        case "binary":
            return "BINARY"
        case "boolean":
            return "BOOLEAN"
        case "date":
            return "DATE"
        case "time":
            return "TIME"
        case "timestamp_ntz":
            return "TIMESTAMP_NTZ"
        case "timestamp_ltz":
            return "TIMESTAMP_LTZ"
        case "timestamp_tz":
            return "TIMESTAMP_TZ"
        case "variant":
            return "VARIANT"
        case "object":
            return "OBJECT"
        case "array":
            return "ARRAY"
        case "geography":
            return "GEOGRAPHY"
        case "geometry":
            return "GEOMETRY"
        default:
            return column.internalType.uppercased()
        }
    }

    /// Snowflake's v1 query protocol returns every cell as a JSON string or null.
    static func cellValue(from json: Any?) -> PluginCellValue {
        switch json {
        case nil, is NSNull:
            return .null
        case let string as String:
            return .text(string)
        case let number as NSNumber:
            return .text(number.stringValue)
        case let bool as Bool:
            return .text(bool ? "true" : "false")
        default:
            return .text(String(describing: json ?? ""))
        }
    }

    static func columnInfo(from column: SnowflakeColumnMeta, primaryKeys: Set<String>) -> PluginColumnInfo {
        PluginColumnInfo(
            name: column.name,
            dataType: displayType(for: column),
            isNullable: column.nullable,
            isPrimaryKey: primaryKeys.contains(column.name.uppercased())
        )
    }
}

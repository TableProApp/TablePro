//
//  SnowflakeTypeMapper.swift
//  SnowflakeDriverPlugin
//
//  Maps Snowflake's internal row metadata types to display type names.
//

import Foundation

struct SnowflakeColumnMeta: Sendable {
    let name: String
    let internalType: String
    let nullable: Bool
    let precision: Int?
    let scale: Int?
    let length: Int?
}

/// The `type` field of a `rowtype` entry, parsed once. Both the display name and the wire decoding
/// are decided from this, so the two cannot drift into disagreeing about what a column holds.
enum SnowflakeLogicalType: String, Sendable, CaseIterable {
    case fixed = "FIXED"
    case real = "REAL"
    case text = "TEXT"
    case binary = "BINARY"
    case boolean = "BOOLEAN"
    case date = "DATE"
    case time = "TIME"
    case timestampNtz = "TIMESTAMP_NTZ"
    case timestampLtz = "TIMESTAMP_LTZ"
    case timestampTz = "TIMESTAMP_TZ"
    case variant = "VARIANT"
    case object = "OBJECT"
    case array = "ARRAY"
    case geography = "GEOGRAPHY"
    case geometry = "GEOMETRY"

    init?(internalType: String) {
        self.init(rawValue: internalType.uppercased())
    }
}

enum SnowflakeTypeMapper {
    static func displayType(for column: SnowflakeColumnMeta) -> String {
        guard let type = SnowflakeLogicalType(internalType: column.internalType) else {
            return column.internalType.uppercased()
        }
        switch type {
        case .fixed:
            if let scale = column.scale, scale > 0 {
                return "NUMBER(\(column.precision ?? 38),\(scale))"
            }
            return "NUMBER"
        case .real:
            return "FLOAT"
        case .text:
            if let length = column.length, length > 0 {
                return "VARCHAR(\(length))"
            }
            return "VARCHAR"
        case .binary, .boolean, .date, .time, .timestampNtz, .timestampLtz, .timestampTz,
             .variant, .object, .array, .geography, .geometry:
            return type.rawValue
        }
    }
}

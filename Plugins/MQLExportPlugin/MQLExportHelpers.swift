//
//  MQLExportHelpers.swift
//  MQLExportPlugin
//

import Foundation
import TableProNumberFormatting
import TableProPluginKit

enum MQLExportHelpers {
    static func escapeJSIdentifier(_ name: String) -> String {
        guard let firstChar = name.first,
              !firstChar.isNumber,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return "[\"\(PluginExportUtilities.escapeJSONString(name))\"]"
        }
        return name
    }

    static func collectionAccessor(for name: String) -> String {
        let escaped = escapeJSIdentifier(name)
        if escaped.hasPrefix("[") {
            return "db\(escaped)"
        }
        return "db.\(escaped)"
    }

    static func mqlBinaryValue(for data: Data, subtype: UInt8) -> String {
        MongoDBUuidCodec.binaryText(for: MongoDBBinaryValue(data: data, subtype: subtype))
    }

    /// A mongosh script inserts a string wherever it sees one, so a typed scalar has to be
    /// written as its constructor. The column type is the only surviving record of the type.
    static func mqlTextValue(for value: String, columnTypeName: String) -> String {
        switch columnTypeName {
        case "ObjectId":
            let objectId = MongoDBObjectId(hex: value)
            guard objectId.isValid else { break }
            return "ObjectId(\"\(PluginExportUtilities.escapeJSONString(value))\")"
        case "TIMESTAMP":
            guard isIso8601(value) else { break }
            return "ISODate(\"\(PluginExportUtilities.escapeJSONString(value))\")"
        case "DECIMAL":
            guard NumberText.isJSONNumberLiteral(value) else { break }
            return "NumberDecimal(\"\(PluginExportUtilities.escapeJSONString(value))\")"
        default:
            break
        }
        return mqlJsonValue(for: value)
    }

    private static func isIso8601(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    static func mqlJsonValue(for value: String) -> String {
        if value == "true" || value == "false" {
            return value
        }
        if value == "null" {
            return "null"
        }
        if NumberText.isJSONNumber(value) {
            return value
        }
        if let binary = MongoDBUuidCodec.parseWrapper(value) {
            return MongoDBUuidCodec.binaryText(for: binary)
        }
        if (value.hasPrefix("{") && value.hasSuffix("}")) ||
            (value.hasPrefix("[") && value.hasSuffix("]")) {
            if let data = value.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return value
            }
            return "\"\(PluginExportUtilities.escapeJSONString(value))\""
        }
        return "\"\(PluginExportUtilities.escapeJSONString(value))\""
    }
}

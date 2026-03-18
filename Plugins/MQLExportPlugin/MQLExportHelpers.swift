//
//  MQLExportHelpers.swift
//  MQLExportPlugin
//

import Foundation
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

    static func mqlJsonValue(for value: String) -> String {
        if value == "true" || value == "false" {
            return value
        }
        if value == "null" {
            return "null"
        }
        if Int64(value) != nil {
            return value
        }
        if Double(value) != nil, value.contains(".") {
            return value
        }
        if (value.hasPrefix("{") && value.hasSuffix("}")) ||
            (value.hasPrefix("[") && value.hasSuffix("]")) {
            let hasControlChars = value.utf8.contains(where: { $0 < 0x20 })
            if hasControlChars {
                return "\"\(PluginExportUtilities.escapeJSONString(value))\""
            }
            return value
        }
        return "\"\(PluginExportUtilities.escapeJSONString(value))\""
    }
}

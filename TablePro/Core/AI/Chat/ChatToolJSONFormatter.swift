//
//  ChatToolJSONFormatter.swift
//  TablePro
//

import Foundation

/// JSON-encode a `JsonValue` (MCP wire type) as a string for inclusion in a
/// `ChatToolResult`. The chat layer needs strings; MCP bridges return `JsonValue`.
enum ChatToolJSONFormatter {
    static func string(from value: JsonValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

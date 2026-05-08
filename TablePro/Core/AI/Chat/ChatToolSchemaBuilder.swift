//
//  ChatToolSchemaBuilder.swift
//  TablePro
//

import Foundation

enum ChatToolSchemaBuilder {
    static func object(properties: [String: JsonValue], required: [String] = []) -> JsonValue {
        var fields: [String: JsonValue] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            fields["required"] = .array(required.map(JsonValue.string))
        }
        return .object(fields)
    }

    static func string(description: String) -> JsonValue {
        .object([
            "type": .string("string"),
            "description": .string(description)
        ])
    }

    static func enumString(_ values: [String], description: String) -> JsonValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JsonValue.string)),
            "description": .string(description)
        ])
    }

    static func boolean(description: String) -> JsonValue {
        .object([
            "type": .string("boolean"),
            "description": .string(description)
        ])
    }

    static func integer(description: String) -> JsonValue {
        .object([
            "type": .string("integer"),
            "description": .string(description)
        ])
    }
}

extension ChatToolSchemaBuilder {
    static var connectionId: JsonValue {
        string(description: "UUID of the connection")
    }

    static var schemaName: JsonValue {
        string(description: "Schema name (uses current if omitted)")
    }
}

//
//  ChatToolSchemaBuilder.swift
//  TablePro
//

import Foundation

enum ChatToolSchemaBuilder {
    static func object(
        properties: [String: JsonValue],
        required: [String]? = nil
    ) -> JsonValue {
        let resolvedRequired = required ?? Array(properties.keys)
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(resolvedRequired.map(JsonValue.string)),
            "additionalProperties": .bool(false)
        ])
    }

    static func string(description: String, optional: Bool = false) -> JsonValue {
        scalar("string", description: description, optional: optional)
    }

    static func enumString(_ values: [String], description: String, optional: Bool = false) -> JsonValue {
        var members = values.map(JsonValue.string)
        if optional {
            members.append(.null)
        }
        return scalar("string", description: description, optional: optional, extras: [
            "enum": .array(members)
        ])
    }

    static func boolean(description: String, optional: Bool = false) -> JsonValue {
        scalar("boolean", description: description, optional: optional)
    }

    static func integer(description: String, optional: Bool = false) -> JsonValue {
        scalar("integer", description: description, optional: optional)
    }

    private static func scalar(
        _ typeName: String,
        description: String,
        optional: Bool,
        extras: [String: JsonValue] = [:]
    ) -> JsonValue {
        let baseType: JsonValue = optional
            ? .array([.string(typeName), .string("null")])
            : .string(typeName)
        var fields: [String: JsonValue] = [
            "type": baseType,
            "description": .string(description)
        ]
        for (key, value) in extras {
            fields[key] = value
        }
        return .object(fields)
    }
}

extension ChatToolSchemaBuilder {
    static var connectionId: JsonValue {
        string(description: "UUID of the connection")
    }

    static var schemaName: JsonValue {
        string(description: "Schema name (uses current if omitted)", optional: true)
    }
}

import Foundation

enum MCPToolSchema {
    static func object(
        properties: [String: JsonValue],
        required: [String] = [],
        allowsAdditional: Bool = false
    ) -> JsonValue {
        var fields: [String: JsonValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(allowsAdditional)
        ]
        if !required.isEmpty {
            fields["required"] = .array(required.sorted().map { .string($0) })
        }
        return .object(fields)
    }

    static let empty: JsonValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false)
    ])

    static func string(_ description: String) -> JsonValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func string(_ description: String, enumValues: [String]) -> JsonValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(enumValues.map { .string($0) })
        ])
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JsonValue {
        var fields: [String: JsonValue] = [
            "type": .string("integer"),
            "description": .string(description)
        ]
        if let minimum {
            fields["minimum"] = .int(minimum)
        }
        if let maximum {
            fields["maximum"] = .int(maximum)
        }
        return .object(fields)
    }

    static func number(_ description: String) -> JsonValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    static func boolean(_ description: String) -> JsonValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    static func array(_ description: String, of items: JsonValue) -> JsonValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": items
        ])
    }

    static let anyValue: JsonValue = .object([:])

    static let stringItem: JsonValue = .object(["type": .string("string")])

    static let connectionId = string(String(localized: "UUID of the connection"))
    static let database = string(String(localized: "Database name. Uses the connection's current database when omitted."))
    static let schema = string(String(localized: "Schema name. Uses the connection's current schema when omitted."))
    static let table = string(String(localized: "Table or view name"))

    static func nullableString(_ description: String) -> JsonValue {
        .object([
            "type": .array([.string("string"), .string("null")]),
            "description": .string(description)
        ])
    }

    static let cell: JsonValue = .object([
        "description": .string(String(localized: "Cell value: string, number, boolean, or null"))
    ])

    static let resultSet: JsonValue = object(
        properties: [
            "columns": array(String(localized: "Column names in result order"), of: stringItem),
            "rows": array(
                String(localized: "Rows, each an array aligned with columns"),
                of: .object(["type": .string("array"), "items": cell])
            ),
            "row_count": integer(String(localized: "Number of rows returned")),
            "rows_affected": integer(String(localized: "Rows the statement changed")),
            "execution_time_ms": number(String(localized: "Server round trip in milliseconds")),
            "is_truncated": boolean(String(localized: "Whether the row limit clipped the result")),
            "status_message": string(String(localized: "Driver status message, when the engine sent one")),
            "database": string(String(localized: "Database the statement ran against")),
            "schema": string(String(localized: "Schema the statement ran against"))
        ],
        required: ["columns", "rows", "row_count", "rows_affected", "execution_time_ms", "is_truncated"],
        allowsAdditional: true
    )

    static let columnDefinition: JsonValue = object(
        properties: [
            "name": string(String(localized: "Column name")),
            "data_type": string(String(localized: "Declared column type")),
            "is_nullable": boolean(String(localized: "Whether the column accepts NULL")),
            "is_primary_key": boolean(String(localized: "Whether the column is part of the primary key")),
            "is_generated": boolean(String(localized: "Whether the column is generated")),
            "default_value": string(String(localized: "Column default expression")),
            "extra": string(String(localized: "Engine-specific column attributes")),
            "comment": string(String(localized: "Column comment")),
            "allowed_values": array(String(localized: "Enumerated values the column accepts"), of: stringItem)
        ],
        required: ["name", "data_type", "is_nullable", "is_primary_key"],
        allowsAdditional: true
    )

    static let indexDefinition: JsonValue = object(
        properties: [
            "name": string(String(localized: "Index name")),
            "columns": array(String(localized: "Indexed columns in order"), of: stringItem),
            "is_unique": boolean(String(localized: "Whether the index enforces uniqueness")),
            "is_primary": boolean(String(localized: "Whether the index backs the primary key")),
            "type": string(String(localized: "Index type reported by the engine")),
            "where_clause": string(String(localized: "Partial index predicate"))
        ],
        required: ["name", "columns", "is_unique", "is_primary", "type"],
        allowsAdditional: true
    )

    static let foreignKeyDefinition: JsonValue = object(
        properties: [
            "name": string(String(localized: "Constraint name")),
            "column": string(String(localized: "Referencing column")),
            "referenced_table": string(String(localized: "Referenced table")),
            "referenced_column": string(String(localized: "Referenced column")),
            "referenced_schema": string(String(localized: "Referenced schema")),
            "on_delete": string(String(localized: "ON DELETE action")),
            "on_update": string(String(localized: "ON UPDATE action"))
        ],
        required: ["name", "column", "referenced_table", "referenced_column", "on_delete", "on_update"],
        allowsAdditional: true
    )

    static let tableSummary: JsonValue = object(
        properties: [
            "name": string(String(localized: "Table name")),
            "type": string(String(localized: "Object type reported by the engine")),
            "schema": string(String(localized: "Schema the object belongs to")),
            "comment": string(String(localized: "Table comment")),
            "row_count": integer(String(localized: "Approximate row count, when requested"))
        ],
        required: ["name", "type"],
        allowsAdditional: true
    )
}

//
//  ChatToolSpec+Copilot.swift
//  TablePro
//

import Foundation

extension ChatToolSpec {
    func asCopilotToolInformation() -> CopilotLanguageModelToolInformation {
        CopilotLanguageModelToolInformation(
            name: name,
            description: description,
            inputSchema: Self.sanitizeForCopilot(inputSchema)
        )
    }

    /// Copilot's LSP schema validator rejects `type: [X, "null"]` arrays. Every
    /// `type` field must be a single string. Convert nullable scalars to plain
    /// scalars and drop the property from the parent's `required` array so the
    /// model knows it can omit the field. Recurses into nested objects and array
    /// items.
    static func sanitizeForCopilot(_ schema: JsonValue) -> JsonValue {
        switch schema {
        case .object(let fields):
            return sanitizeObject(fields)
        case .array(let items):
            return .array(items.map(sanitizeForCopilot))
        default:
            return schema
        }
    }

    private static func sanitizeObject(_ fields: [String: JsonValue]) -> JsonValue {
        var nullableKeys: Set<String> = []
        var rewritten: [String: JsonValue] = [:]

        for (key, value) in fields {
            if key == "properties", case .object(let props) = value {
                var cleanedProps: [String: JsonValue] = [:]
                for (propName, propValue) in props {
                    let (cleaned, wasNullable) = stripNullableType(propValue)
                    if wasNullable {
                        nullableKeys.insert(propName)
                    }
                    cleanedProps[propName] = sanitizeForCopilot(cleaned)
                }
                rewritten[key] = .object(cleanedProps)
            } else {
                rewritten[key] = sanitizeForCopilot(value)
            }
        }

        if !nullableKeys.isEmpty, case .array(let required) = rewritten["required"] {
            let filtered = required.filter { entry in
                if case .string(let name) = entry { return !nullableKeys.contains(name) }
                return true
            }
            rewritten["required"] = .array(filtered)
        }

        return .object(rewritten)
    }

    /// Rewrites `type: [X, "null"]` to `type: X` on a property schema.
    /// Also strips `null` from `enum` arrays if present.
    /// Returns the cleaned schema and whether the original was nullable.
    private static func stripNullableType(_ schema: JsonValue) -> (JsonValue, Bool) {
        guard case .object(var fields) = schema,
              case .array(let typeMembers) = fields["type"]
        else {
            return (schema, false)
        }

        let nullCount = typeMembers.filter { $0 == .string("null") }.count
        guard nullCount > 0 else { return (schema, false) }

        let nonNull = typeMembers.filter { $0 != .string("null") }
        if nonNull.count == 1, let primary = nonNull.first {
            fields["type"] = primary
        } else {
            fields["type"] = .array(nonNull)
        }

        if case .array(let enumMembers) = fields["enum"] {
            fields["enum"] = .array(enumMembers.filter { $0 != .null })
        }

        return (.object(fields), true)
    }
}

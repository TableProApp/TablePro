//
//  MCPOutputSchemaConformance.swift
//  TableProTests
//

import Foundation
@testable import TablePro

enum MCPOutputSchemaConformance {
    static func violations(of value: JsonValue, against schema: JsonValue, at path: String = "$") -> [String] {
        let types = declaredTypes(of: schema)
        if !types.isEmpty, !types.contains(where: { value.matches(schemaType: $0) }) {
            return ["\(path) is not \(types.joined(separator: " or "))"]
        }
        switch value {
        case .object(let fields):
            return objectViolations(fields, against: schema, at: path)
        case .array(let items):
            guard let itemSchema = schema["items"] else { return [] }
            return items.enumerated().flatMap { offset, item in
                violations(of: item, against: itemSchema, at: "\(path)[\(offset)]")
            }
        default:
            return []
        }
    }

    private static func declaredTypes(of schema: JsonValue) -> [String] {
        if let single = schema["type"]?.stringValue {
            return [single]
        }
        return schema["type"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private static func objectViolations(
        _ fields: [String: JsonValue],
        against schema: JsonValue,
        at path: String
    ) -> [String] {
        let properties = schema["properties"]?.objectValue ?? [:]
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let isClosed = schema["additionalProperties"]?.boolValue == false

        var found = required
            .filter { fields[$0] == nil }
            .map { "\(path) is missing required \($0)" }
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            guard let propertySchema = properties[key] else {
                if isClosed {
                    found.append("\(path) has undeclared \(key)")
                }
                continue
            }
            found.append(contentsOf: violations(of: value, against: propertySchema, at: "\(path).\(key)"))
        }
        return found
    }
}

private extension JsonValue {
    func matches(schemaType: String) -> Bool {
        switch (schemaType, self) {
        case ("null", .null), ("boolean", .bool), ("integer", .int), ("string", .string),
             ("array", .array), ("object", .object):
            return true
        case ("number", .int), ("number", .double):
            return true
        default:
            return false
        }
    }
}

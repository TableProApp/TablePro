//
//  AvroSchema.swift
//  TablePro
//

import Foundation

internal enum AvroLogicalType: Equatable, Sendable {
    case decimal(scale: Int)
    case uuid
    case date
    case timeMillis
    case timeMicros
    case timestampMillis
    case timestampMicros
    case localTimestampMillis
    case localTimestampMicros
}

internal struct AvroField: Equatable, Sendable {
    let name: String
    let type: AvroType
}

internal indirect enum AvroType: Equatable, Sendable {
    case null
    case boolean
    case int
    case long
    case float
    case double
    case bytes
    case string
    case record(name: String, fields: [AvroField])
    case enumeration(name: String, symbols: [String])
    case array(AvroType)
    case map(AvroType)
    case union([AvroType])
    case fixed(name: String, size: Int)
    case named(String)
    case logical(AvroLogicalType, AvroType)
}

internal struct AvroSchemaError: Error, Equatable, Sendable {
    let reason: String
}

// https://avro.apache.org/docs/1.12.0/specification/
// A named type is stored once and referenced by full name, so a recursive record parses.
internal struct AvroSchema: Equatable, Sendable {
    let root: AvroType
    let namedTypes: [String: AvroType]

    static func parse(_ text: String) throws -> AvroSchema {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        } catch {
            throw AvroSchemaError(reason: String(localized: "The schema is not valid JSON."))
        }
        var parser = Parser()
        let root = try parser.type(json, namespace: nil)
        return AvroSchema(root: root, namedTypes: parser.namedTypes)
    }

    // Far past any engine's decimal; a larger one would only let a schema file pad a cell with zeros.
    static let maxDecimalPrecision = 1_000

    func resolve(_ type: AvroType) -> AvroType {
        if case .named(let name) = type, let defined = namedTypes[name] { return defined }
        return type
    }

    // Items of these types take no bytes, so an array of them can hold more items than bytes remain.
    func takesNoBytes(_ type: AvroType, visiting: Set<String> = []) -> Bool {
        switch resolve(type) {
        case .null: return true
        case .fixed(_, let size): return size == 0
        case .logical(_, let base): return takesNoBytes(base, visiting: visiting)
        case .record(let name, let fields):
            guard !visiting.contains(name) else { return false }
            return fields.allSatisfy { takesNoBytes($0.type, visiting: visiting.union([name])) }
        default: return false
        }
    }

    private struct Parser {
        var namedTypes: [String: AvroType] = [:]

        mutating func type(_ json: Any, namespace: String?) throws -> AvroType {
            if let name = json as? String {
                return try reference(name, namespace: namespace)
            }
            if let branches = json as? [Any] {
                return .union(try branches.map { try type($0, namespace: namespace) })
            }
            guard let object = json as? [String: Any] else {
                throw AvroSchemaError(reason: String(localized: "The schema has a type that is not a name, an object or a union."))
            }
            let base = try complex(object, namespace: namespace)
            guard let logicalName = object["logicalType"] as? String,
                  let logical = Self.logical(logicalName, object: object, base: base) else { return base }
            return .logical(logical, base)
        }

        private mutating func complex(_ object: [String: Any], namespace: String?) throws -> AvroType {
            guard let typeName = object["type"] else {
                throw AvroSchemaError(reason: String(localized: "A schema object has no \"type\"."))
            }
            guard let kind = typeName as? String else { return try type(typeName, namespace: namespace) }
            switch kind {
            case "record", "error":
                let name = try fullName(object, namespace: namespace)
                namedTypes[name] = .record(name: name, fields: [])
                let inner = Self.namespace(of: name)
                guard let rawFields = object["fields"] as? [[String: Any]] else {
                    throw AvroSchemaError(reason: String(format: String(localized: "Record %@ has no fields list."), name))
                }
                let fields = try rawFields.map { field -> AvroField in
                    guard let fieldName = field["name"] as? String, let fieldType = field["type"] else {
                        throw AvroSchemaError(reason: String(format: String(localized: "A field of record %@ has no name or type."), name))
                    }
                    return AvroField(name: fieldName, type: try type(fieldType, namespace: inner))
                }
                let record = AvroType.record(name: name, fields: fields)
                namedTypes[name] = record
                return record
            case "enum":
                let name = try fullName(object, namespace: namespace)
                guard let symbols = object["symbols"] as? [String] else {
                    throw AvroSchemaError(reason: String(format: String(localized: "Enum %@ has no symbols."), name))
                }
                let enumeration = AvroType.enumeration(name: name, symbols: symbols)
                namedTypes[name] = enumeration
                return enumeration
            case "fixed":
                let name = try fullName(object, namespace: namespace)
                guard let size = object["size"] as? Int, size >= 0 else {
                    throw AvroSchemaError(reason: String(format: String(localized: "Fixed type %@ has no size."), name))
                }
                let fixed = AvroType.fixed(name: name, size: size)
                namedTypes[name] = fixed
                return fixed
            case "array":
                guard let items = object["items"] else {
                    throw AvroSchemaError(reason: String(localized: "An array has no \"items\"."))
                }
                return .array(try type(items, namespace: namespace))
            case "map":
                guard let values = object["values"] else {
                    throw AvroSchemaError(reason: String(localized: "A map has no \"values\"."))
                }
                return .map(try type(values, namespace: namespace))
            default:
                return try reference(kind, namespace: namespace)
            }
        }

        private func reference(_ name: String, namespace: String?) throws -> AvroType {
            switch name {
            case "null": return .null
            case "boolean": return .boolean
            case "int": return .int
            case "long": return .long
            case "float": return .float
            case "double": return .double
            case "bytes": return .bytes
            case "string": return .string
            default: break
            }
            if !name.contains("."), let namespace, namedTypes["\(namespace).\(name)"] != nil {
                return .named("\(namespace).\(name)")
            }
            guard namedTypes[name] != nil else {
                throw AvroSchemaError(reason: String(format: String(localized: "The schema names type %@ before defining it."), name))
            }
            return .named(name)
        }

        private func fullName(_ object: [String: Any], namespace: String?) throws -> String {
            guard let name = object["name"] as? String, !name.isEmpty else {
                throw AvroSchemaError(reason: String(localized: "A record, enum or fixed type has no name."))
            }
            if name.contains(".") { return name }
            let space = object["namespace"] as? String ?? namespace
            guard let space, !space.isEmpty else { return name }
            return "\(space).\(name)"
        }

        private static func namespace(of fullName: String) -> String? {
            guard let dot = fullName.lastIndex(of: ".") else { return nil }
            return String(fullName[..<dot])
        }

        // An unknown or misapplied logical type falls back to its underlying type, as the specification says.
        private static func logical(_ name: String, object: [String: Any], base: AvroType) -> AvroLogicalType? {
            switch (name, base) {
            case ("decimal", .bytes), ("decimal", .fixed):
                guard let precision = object["precision"] as? Int, (1...AvroSchema.maxDecimalPrecision).contains(precision) else { return nil }
                let scale = object["scale"] as? Int ?? 0
                return (0...precision).contains(scale) ? .decimal(scale: scale) : nil
            case ("uuid", .string), ("uuid", .fixed(_, 16)): return .uuid
            case ("date", .int): return .date
            case ("time-millis", .int): return .timeMillis
            case ("time-micros", .long): return .timeMicros
            case ("timestamp-millis", .long): return .timestampMillis
            case ("timestamp-micros", .long): return .timestampMicros
            case ("local-timestamp-millis", .long): return .localTimestampMillis
            case ("local-timestamp-micros", .long): return .localTimestampMicros
            default: return nil
            }
        }
    }
}

//
//  AvroSchema.swift
//  TablePro
//

import Foundation

internal enum AvroLogicalType: Equatable, Sendable {
    case decimal(precision: Int, scale: Int)
    case uuid
    case date
    case timeMillis
    case timeMicros
    case timestampMillis
    case timestampMicros
    case timestampNanos
    case localTimestampMillis
    case localTimestampMicros
    case localTimestampNanos
    case duration
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
    // CRC-64-AVRO of the Parsing Canonical Form, what a single-object encoded value names its writer schema by.
    let fingerprint: UInt64
    // Named types whose values take no bytes, worked out once: walking a shared type on every check is exponential.
    let zeroByteNames: Set<String>

    static func parse(_ text: String) throws -> AvroSchema {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        } catch {
            throw AvroSchemaError(reason: String(localized: "The schema is not valid JSON."))
        }
        var parser = Parser()
        let root = try parser.type(json, namespace: nil)
        return AvroSchema(
            root: root,
            namedTypes: parser.namedTypes,
            fingerprint: fingerprint(of: canonicalForm(root)),
            zeroByteNames: zeroByteNames(parser.namedTypes)
        )
    }

    private static func zeroByteNames(_ namedTypes: [String: AvroType]) -> Set<String> {
        var known: [String: Bool] = [:]
        func takesNoBytes(_ type: AvroType, visiting: Set<String>) -> Bool {
            switch type {
            case .null: return true
            case .fixed(_, let size): return size == 0
            case .logical(_, let base): return takesNoBytes(base, visiting: visiting)
            case .named(let name):
                if let answer = known[name] { return answer }
                guard !visiting.contains(name), let defined = namedTypes[name] else { return false }
                let answer = takesNoBytes(defined, visiting: visiting.union([name]))
                known[name] = answer
                return answer
            case .record(let name, let fields):
                if let answer = known[name] { return answer }
                let answer = fields.allSatisfy { takesNoBytes($0.type, visiting: visiting.union([name])) }
                known[name] = answer
                return answer
            default: return false
            }
        }
        return Set(namedTypes.keys.filter { takesNoBytes(.named($0), visiting: []) })
    }

    // https://avro.apache.org/docs/1.12.0/specification/#parsing-canonical-form-for-schemas
    // Full names, only the attributes that shape the bytes, in the specified order, no whitespace. A named
    // type is written out where the schema defines it and by name everywhere else, as the parsed tree holds it.
    static func canonicalForm(_ type: AvroType) -> String {
        switch type {
        case .null: return #""null""#
        case .boolean: return #""boolean""#
        case .int: return #""int""#
        case .long: return #""long""#
        case .float: return #""float""#
        case .double: return #""double""#
        case .bytes: return #""bytes""#
        case .string: return #""string""#
        case .named(let name): return quoted(name)
        case .logical(_, let base): return canonicalForm(base)
        case .union(let branches): return "[" + branches.map(canonicalForm).joined(separator: ",") + "]"
        case .array(let items): return #"{"type":"array","items":"# + canonicalForm(items) + "}"
        case .map(let values): return #"{"type":"map","values":"# + canonicalForm(values) + "}"
        case .fixed(let name, let size): return #"{"name":"# + quoted(name) + #","type":"fixed","size":"# + "\(size)}"
        case .enumeration(let name, let symbols):
            return #"{"name":"# + quoted(name) + #","type":"enum","symbols":["# + symbols.map(quoted).joined(separator: ",") + "]}"
        case .record(let name, let fields):
            let members = fields.map { #"{"name":"# + quoted($0.name) + #","type":"# + canonicalForm($0.type) + "}" }
            return #"{"name":"# + quoted(name) + #","type":"record","fields":["# + members.joined(separator: ",") + "]}"
        }
    }

    static func fingerprint(of canonicalForm: String) -> UInt64 {
        canonicalForm.utf8.reduce(emptyFingerprint) { ($0 >> 8) ^ fingerprintTable[Int(($0 ^ UInt64($1)) & 0xFF)] }
    }

    private static let emptyFingerprint: UInt64 = 0xC15D_213A_A4D7_A795

    private static let fingerprintTable: [UInt64] = (0..<256).map { index in
        var value = UInt64(index)
        for _ in 0..<8 {
            value = (value >> 1) ^ (emptyFingerprint & (0 &- (value & 1)))
        }
        return value
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // Far past any engine's decimal; a larger one would only let a schema file pad a cell with zeros.
    static let maxDecimalPrecision = 1_000

    // The root type's own name, without its namespace, for menus.
    var displayName: String? {
        Self.name(of: root)
    }

    private static func name(of type: AvroType) -> String? {
        switch type {
        case .record(let name, _), .enumeration(let name, _), .fixed(let name, _), .named(let name):
            return name.split(separator: ".").last.map(String.init)
        case .logical(_, let base):
            return Self.name(of: base)
        case .union(let branches):
            return branches.lazy.compactMap { Self.name(of: $0) }.first
        case .array, .map, .null, .boolean, .int, .long, .float, .double, .bytes, .string:
            return nil
        }
    }

    func resolve(_ type: AvroType) -> AvroType {
        if case .named(let name) = type, let defined = namedTypes[name] { return defined }
        return type
    }

    // Items of these types take no bytes, so an array of them can hold more items than bytes remain.
    func takesNoBytes(_ type: AvroType) -> Bool {
        switch type {
        case .null: return true
        case .fixed(_, let size): return size == 0
        case .logical(_, let base): return takesNoBytes(base)
        case .named(let name), .record(let name, _): return zeroByteNames.contains(name)
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
            let annotated = AvroType.logical(logical, base)
            // The logical type belongs to the named type, so a later reference by name keeps it.
            if case .fixed(let name, _) = base { namedTypes[name] = annotated }
            return annotated
        }

        private mutating func complex(_ object: [String: Any], namespace: String?) throws -> AvroType {
            guard let typeName = object["type"] else {
                throw AvroSchemaError(reason: String(localized: "A schema object has no \"type\"."))
            }
            guard let kind = typeName as? String else { return try type(typeName, namespace: namespace) }
            switch kind {
            case "record", "error":
                let name = try newName(object, namespace: namespace)
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
                let name = try newName(object, namespace: namespace)
                guard let symbols = object["symbols"] as? [String] else {
                    throw AvroSchemaError(reason: String(format: String(localized: "Enum %@ has no symbols."), name))
                }
                let enumeration = AvroType.enumeration(name: name, symbols: symbols)
                namedTypes[name] = enumeration
                return enumeration
            case "fixed":
                let name = try newName(object, namespace: namespace)
                guard let size = Self.integer(object["size"]), size >= 0 else {
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

        private func newName(_ object: [String: Any], namespace: String?) throws -> String {
            guard let name = object["name"] as? String, !name.isEmpty else {
                throw AvroSchemaError(reason: String(localized: "A record, enum or fixed type has no name."))
            }
            var fullName = name
            if !name.contains("."), let space = object["namespace"] as? String ?? namespace, !space.isEmpty {
                fullName = "\(space).\(name)"
            }
            guard namedTypes[fullName] == nil else {
                throw AvroSchemaError(reason: String(format: String(localized: "The schema defines type %@ twice."), fullName))
            }
            return fullName
        }

        private static func namespace(of fullName: String) -> String? {
            guard let dot = fullName.lastIndex(of: ".") else { return nil }
            return String(fullName[..<dot])
        }

        // An unknown or misapplied logical type falls back to its underlying type, as the specification says.
        private static func logical(_ name: String, object: [String: Any], base: AvroType) -> AvroLogicalType? {
            switch (name, base) {
            case ("decimal", .bytes):
                return decimal(object, maxPrecision: AvroSchema.maxDecimalPrecision)
            case ("decimal", .fixed(_, let size)):
                return decimal(object, maxPrecision: min(AvroSchema.maxDecimalPrecision, AvroDecimal.maxPrecision(bytes: size)))
            case ("uuid", .string), ("uuid", .fixed(_, 16)): return .uuid
            case ("date", .int): return .date
            case ("time-millis", .int): return .timeMillis
            case ("time-micros", .long): return .timeMicros
            case ("timestamp-millis", .long): return .timestampMillis
            case ("timestamp-micros", .long): return .timestampMicros
            case ("timestamp-nanos", .long): return .timestampNanos
            case ("local-timestamp-millis", .long): return .localTimestampMillis
            case ("local-timestamp-micros", .long): return .localTimestampMicros
            case ("local-timestamp-nanos", .long): return .localTimestampNanos
            case ("duration", .fixed(_, 12)): return .duration
            default: return nil
            }
        }

        private static func decimal(_ object: [String: Any], maxPrecision: Int) -> AvroLogicalType? {
            guard let precision = integer(object["precision"]), precision >= 1, precision <= maxPrecision else { return nil }
            let scale = object["scale"] == nil ? 0 : integer(object["scale"]) ?? -1
            return (0...precision).contains(scale) ? .decimal(precision: precision, scale: scale) : nil
        }

        // `as? Int` also takes `true` and `4.0`, which Avro's own parser refuses as a size, precision or scale.
        private static func integer(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !CFNumberIsFloatType(number) else { return nil }
            return Int(exactly: number.int64Value)
        }
    }
}

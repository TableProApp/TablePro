import CoreFoundation
import Foundation
import TableProGoogleCloud
import TableProPluginKit

internal final class BigQueryParameterType: Codable, Sendable, Equatable {
    let type: String
    let arrayType: BigQueryParameterType?
    let structTypes: [BigQueryStructFieldType]?
    let rangeElementType: BigQueryParameterType?

    init(
        type: String,
        arrayType: BigQueryParameterType? = nil,
        structTypes: [BigQueryStructFieldType]? = nil,
        rangeElementType: BigQueryParameterType? = nil
    ) {
        self.type = type
        self.arrayType = arrayType
        self.structTypes = structTypes
        self.rangeElementType = rangeElementType
    }

    static let string = BigQueryParameterType(type: "STRING")

    static func == (lhs: BigQueryParameterType, rhs: BigQueryParameterType) -> Bool {
        lhs.type == rhs.type
            && lhs.arrayType == rhs.arrayType
            && lhs.structTypes == rhs.structTypes
            && lhs.rangeElementType == rhs.rangeElementType
    }
}

internal struct BigQueryStructFieldType: Codable, Sendable, Equatable {
    let name: String?
    let type: BigQueryParameterType
}

internal final class BigQueryParameterValue: Codable, Sendable, Equatable {
    let value: String?
    let arrayValues: [BigQueryParameterValue]?
    let structValues: [String: BigQueryParameterValue]?
    let rangeValue: BigQueryRangeValue?

    init(
        value: String? = nil,
        arrayValues: [BigQueryParameterValue]? = nil,
        structValues: [String: BigQueryParameterValue]? = nil,
        rangeValue: BigQueryRangeValue? = nil
    ) {
        self.value = value
        self.arrayValues = arrayValues
        self.structValues = structValues
        self.rangeValue = rangeValue
    }

    static func == (lhs: BigQueryParameterValue, rhs: BigQueryParameterValue) -> Bool {
        lhs.value == rhs.value
            && lhs.arrayValues == rhs.arrayValues
            && lhs.structValues == rhs.structValues
            && lhs.rangeValue == rhs.rangeValue
    }
}

internal struct BigQueryRangeValue: Codable, Sendable, Equatable {
    let start: BigQueryParameterValue?
    let end: BigQueryParameterValue?
}

internal struct BigQueryQueryParameter: Codable, Sendable, Equatable {
    let name: String?
    let parameterType: BigQueryParameterType
    let parameterValue: BigQueryParameterValue?
}

internal struct BigQueryParameterBinding: Sendable, Equatable {
    let name: String
    let position: Int
    let value: PluginCellValue
}

internal struct BigQueryBoundQuery: Sendable, Equatable {
    let sql: String
    let bindings: [BigQueryParameterBinding]
}

internal enum BigQueryParameterEncodingError: Error, Sendable, Equatable {
    case notJSONArray(position: Int)
    case notJSONObject(position: Int)
    case notRange(position: Int)
    case notText(position: Int)
    case unsupportedType(String)
}

internal enum BigQueryQueryParameters {
    static let parameterPrefix = "p"
    static let nullLiteral = "NULL"

    static func name(forPosition position: Int) -> String {
        "\(parameterPrefix)\(position)"
    }

    static func bind(_ query: String, parameters: [PluginCellValue]) throws -> BigQueryBoundQuery {
        let rewritten = try SQLPlaceholderRewriter.rewrite(
            query,
            lexicon: .googleSQL,
            expectedCount: parameters.count
        ) { position in
            guard parameters.indices.contains(position - 1), !parameters[position - 1].isNull else {
                return nullLiteral
            }
            return "@" + name(forPosition: position)
        }
        let bindings = parameters.enumerated().compactMap { offset, value -> BigQueryParameterBinding? in
            guard !value.isNull else { return nil }
            let position = offset + 1
            return BigQueryParameterBinding(name: name(forPosition: position), position: position, value: value)
        }
        return BigQueryBoundQuery(sql: rewritten.sql, bindings: bindings)
    }

    static func discoveredTypes(from parameters: [BigQueryQueryParameter]?) -> [String: BigQueryParameterType] {
        var types: [String: BigQueryParameterType] = [:]
        for parameter in parameters ?? [] {
            guard let name = parameter.name, !name.isEmpty else { continue }
            types[name.lowercased()] = parameter.parameterType
        }
        return types
    }

    static func queryParameters(
        for bindings: [BigQueryParameterBinding],
        types: [String: BigQueryParameterType]
    ) throws -> [BigQueryQueryParameter] {
        try bindings.map { binding in
            let type = types[binding.name.lowercased()] ?? .string
            return BigQueryQueryParameter(
                name: binding.name,
                parameterType: type,
                parameterValue: try encode(binding.value, as: type, position: binding.position)
            )
        }
    }

    static func encode(
        _ cell: PluginCellValue,
        as type: BigQueryParameterType,
        position: Int
    ) throws -> BigQueryParameterValue {
        switch cell {
        case .null:
            return BigQueryParameterValue()
        case .bytes(let data):
            return try encode(bytes: data, as: type, position: position)
        case .text(let text):
            return try encode(text: text, as: type, position: position)
        }
    }

    private static func encode(
        bytes data: Data,
        as type: BigQueryParameterType,
        position: Int
    ) throws -> BigQueryParameterValue {
        if type.type.uppercased() == "BYTES" {
            return BigQueryParameterValue(value: data.base64EncodedString())
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BigQueryParameterEncodingError.notText(position: position)
        }
        return try encode(text: text, as: type, position: position)
    }

    private static func encode(
        text: String,
        as type: BigQueryParameterType,
        position: Int
    ) throws -> BigQueryParameterValue {
        switch type.type.uppercased() {
        case "ARRAY":
            guard let array = parseJSON(text) as? [Any] else {
                throw BigQueryParameterEncodingError.notJSONArray(position: position)
            }
            return try encode(json: array, as: type, position: position)
        case "STRUCT", "RECORD":
            guard let object = parseJSON(text) as? [String: Any] else {
                throw BigQueryParameterEncodingError.notJSONObject(position: position)
            }
            return try encode(json: object, as: type, position: position)
        case "RANGE":
            return try encodeRange(text, position: position)
        default:
            return BigQueryParameterValue(value: text)
        }
    }

    private static func encode(
        json: Any,
        as type: BigQueryParameterType,
        position: Int
    ) throws -> BigQueryParameterValue {
        switch type.type.uppercased() {
        case "ARRAY":
            guard let elements = json as? [Any] else {
                throw BigQueryParameterEncodingError.notJSONArray(position: position)
            }
            guard let elementType = type.arrayType else {
                throw BigQueryParameterEncodingError.unsupportedType(type.type)
            }
            let encoded = try elements.map { try encode(json: $0, as: elementType, position: position) }
            return BigQueryParameterValue(arrayValues: encoded)
        case "STRUCT", "RECORD":
            guard let object = json as? [String: Any] else {
                throw BigQueryParameterEncodingError.notJSONObject(position: position)
            }
            return try encodeStruct(object, as: type, position: position)
        case "RANGE":
            guard let text = json as? String else {
                throw BigQueryParameterEncodingError.notRange(position: position)
            }
            return try encodeRange(text, position: position)
        default:
            return BigQueryParameterValue(value: scalarText(json))
        }
    }

    private static func encodeStruct(
        _ object: [String: Any],
        as type: BigQueryParameterType,
        position: Int
    ) throws -> BigQueryParameterValue {
        var members: [String: BigQueryParameterValue] = [:]
        for field in type.structTypes ?? [] {
            guard let fieldName = field.name, !fieldName.isEmpty else {
                throw BigQueryParameterEncodingError.unsupportedType(type.type)
            }
            guard let member = object[fieldName] else { continue }
            members[fieldName] = try encode(json: member, as: field.type, position: position)
        }
        return BigQueryParameterValue(structValues: members)
    }

    private static func encodeRange(_ text: String, position: Int) throws -> BigQueryParameterValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix(")") else {
            throw BigQueryParameterEncodingError.notRange(position: position)
        }
        let bounds = trimmed.dropFirst().dropLast().components(separatedBy: ",")
        guard bounds.count == 2 else {
            throw BigQueryParameterEncodingError.notRange(position: position)
        }
        return BigQueryParameterValue(
            rangeValue: BigQueryRangeValue(start: rangeBound(bounds[0]), end: rangeBound(bounds[1]))
        )
    }

    private static func rangeBound(_ raw: String) -> BigQueryParameterValue? {
        let bound = raw.trimmingCharacters(in: .whitespaces)
        switch bound.uppercased() {
        case "", "UNBOUNDED", "NULL":
            return nil
        default:
            return BigQueryParameterValue(value: bound)
        }
    }

    private static func parseJSON(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private static func scalarText(_ json: Any) -> String? {
        switch json {
        case let string as String:
            return string
        case let number as NSNumber:
            guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return number.stringValue }
            return number.boolValue ? "true" : "false"
        default:
            return nil
        }
    }
}

internal final class BigQueryParameterTypeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: [String: BigQueryParameterType]] = [:]
    private let capacity: Int

    init(capacity: Int = 256) {
        self.capacity = capacity
    }

    func types(for sql: String) -> [String: BigQueryParameterType]? {
        lock.withLock { entries[sql] }
    }

    func store(_ types: [String: BigQueryParameterType], for sql: String) {
        lock.withLock {
            if entries[sql] == nil, entries.count >= capacity {
                entries.removeAll(keepingCapacity: true)
            }
            entries[sql] = types
        }
    }

    func evict(_ sql: String) {
        lock.withLock { entries[sql] = nil }
    }

    func removeAll() {
        lock.withLock { entries.removeAll() }
    }
}

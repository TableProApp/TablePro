import Foundation

enum DynamoDBAttributeType: String, CaseIterable, Sendable {
    case string = "S"
    case number = "N"
    case binary = "B"
    case boolean = "BOOL"
    case null = "NULL"
    case list = "L"
    case map = "M"
    case stringSet = "SS"
    case numberSet = "NS"
    case binarySet = "BS"

    /// The names the DynamoDB console uses, which is what the grid and the Structure tab show.
    var displayName: String {
        switch self {
        case .string: return "String"
        case .number: return "Number"
        case .binary: return "Binary"
        case .boolean: return "Boolean"
        case .null: return "Null"
        case .list: return "List"
        case .map: return "Map"
        case .stringSet: return "String Set"
        case .numberSet: return "Number Set"
        case .binarySet: return "Binary Set"
        }
    }

    /// The type name the app classifies a column by. A list, a map and every set show as JSON, so
    /// the grid offers the JSON editor for them.
    var classificationName: String {
        switch self {
        case .string, .null: return "TEXT"
        case .number: return "NUMERIC"
        case .binary: return "BLOB"
        case .boolean: return "BOOLEAN"
        case .list, .map, .stringSet, .numberSet, .binarySet: return "JSON"
        }
    }

    var isKeyType: Bool {
        self == .string || self == .number || self == .binary
    }

    init?(displayName: String) {
        guard let match = Self.allCases.first(where: {
            $0.displayName.caseInsensitiveCompare(displayName) == .orderedSame
                || $0.rawValue.caseInsensitiveCompare(displayName) == .orderedSame
        }) else { return nil }
        self = match
    }
}

indirect enum DynamoDBAttributeValue: Sendable, Equatable {
    case string(String)
    case number(String)
    case binary(Data)
    case bool(Bool)
    case null
    case list([DynamoDBAttributeValue])
    case map([String: DynamoDBAttributeValue])
    case stringSet([String])
    case numberSet([String])
    case binarySet([Data])

    var type: DynamoDBAttributeType {
        switch self {
        case .string: return .string
        case .number: return .number
        case .binary: return .binary
        case .bool: return .boolean
        case .null: return .null
        case .list: return .list
        case .map: return .map
        case .stringSet: return .stringSet
        case .numberSet: return .numberSet
        case .binarySet: return .binarySet
        }
    }

    /// The wire form, `{"S": "x"}`, as a JSON tree.
    var wireJSON: DynamoDBJSON {
        switch self {
        case .string(let value):
            return .object(["S": .string(value)])
        case .number(let value):
            return .object(["N": .string(value)])
        case .binary(let value):
            return .object(["B": .string(value.base64EncodedString())])
        case .bool(let value):
            return .object(["BOOL": .bool(value)])
        case .null:
            return .object(["NULL": .bool(true)])
        case .list(let items):
            return .object(["L": .array(items.map(\.wireJSON))])
        case .map(let entries):
            return .object(["M": .object(entries.mapValues(\.wireJSON))])
        case .stringSet(let values):
            return .object(["SS": .array(values.map(DynamoDBJSON.string))])
        case .numberSet(let values):
            return .object(["NS": .array(values.map(DynamoDBJSON.string))])
        case .binarySet(let values):
            return .object(["BS": .array(values.map { .string($0.base64EncodedString()) })])
        }
    }

    init(wireJSON json: DynamoDBJSON) throws {
        guard case .object(let entries) = json, entries.count == 1, let (tag, payload) = entries.first else {
            throw DynamoDBError.invalidResponse(String(localized: "An attribute value must name exactly one type"))
        }
        guard let type = DynamoDBAttributeType(rawValue: tag) else {
            throw DynamoDBError.invalidResponse(
                String(format: String(localized: "Unknown attribute type \"%@\""), tag)
            )
        }
        self = try Self.decode(type: type, payload: payload)
    }

    private static func decode(type: DynamoDBAttributeType, payload: DynamoDBJSON) throws -> DynamoDBAttributeValue {
        switch (type, payload) {
        case (.string, .string(let value)):
            return .string(value)
        case (.number, .string(let value)):
            return .number(value)
        case (.binary, .string(let value)):
            return .binary(try decodeBase64(value))
        case (.boolean, .bool(let value)):
            return .bool(value)
        case (.null, .bool):
            return .null
        case (.list, .array(let items)):
            return .list(try items.map(DynamoDBAttributeValue.init(wireJSON:)))
        case (.map, .object(let entries)):
            return .map(try entries.mapValues(DynamoDBAttributeValue.init(wireJSON:)))
        case (.stringSet, .array(let items)):
            return .stringSet(try items.map(stringPayload))
        case (.numberSet, .array(let items)):
            return .numberSet(try items.map(stringPayload))
        case (.binarySet, .array(let items)):
            return .binarySet(try items.map { try decodeBase64(try stringPayload($0)) })
        default:
            throw DynamoDBError.invalidResponse(
                String(format: String(localized: "A %@ attribute has a payload of the wrong shape"), type.rawValue)
            )
        }
    }

    private static func stringPayload(_ json: DynamoDBJSON) throws -> String {
        guard case .string(let value) = json else {
            throw DynamoDBError.invalidResponse(String(localized: "A set member must be a string"))
        }
        return value
    }

    private static func decodeBase64(_ text: String) throws -> Data {
        guard let data = Data(base64Encoded: text) else {
            throw DynamoDBError.invalidResponse(String(localized: "A binary value is not valid base64"))
        }
        return data
    }
}

typealias DynamoDBItem = [String: DynamoDBAttributeValue]

extension Dictionary where Key == String, Value == DynamoDBAttributeValue {
    var wireJSON: DynamoDBJSON {
        .object(mapValues(\.wireJSON))
    }

    init(wireItem json: DynamoDBJSON) throws {
        guard case .object(let entries) = json else {
            throw DynamoDBError.invalidResponse(String(localized: "An item must be a JSON object"))
        }
        self = try entries.mapValues(DynamoDBAttributeValue.init(wireJSON:))
    }
}

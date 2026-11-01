//
//  ValueDisplayFormat.swift
//  TablePro
//

import Foundation

enum ValueDisplayFormat: Hashable, Codable, Identifiable, RawRepresentable {
    case raw
    case text
    case uuid
    case uuidSwappedTime
    case unixTimestamp
    case unixTimestampMillis
    case json
    case phpSerialized
    case messagePack
    case protobuf
    case igbinary
    // The schema is kept by AvroSchemaStore under this ID, so every per-column path can decode with it.
    case avro(schemaID: String)
    // Kept by ProtobufSchemaStore, with the message type the values are read as.
    case protobufSchema(schemaID: String, message: String)
    // Each value names its schema by ID; the connection says which Schema Registry to fetch it from.
    case schemaRegistry(connectionID: UUID)

    // Every format but Avro, which needs a schema chosen first.
    static let presetFormats: [ValueDisplayFormat] = [
        .raw, .text, .uuid, .uuidSwappedTime, .unixTimestamp, .unixTimestampMillis, .json, .phpSerialized,
        .messagePack, .protobuf, .igbinary,
    ]

    private static let avroPrefix = "avro:"
    private static let protobufSchemaPrefix = "protobuf:"
    private static let schemaRegistryPrefix = "schemaRegistry:"

    init?(rawValue: String) {
        switch rawValue {
        case "raw": self = .raw
        case "text": self = .text
        case "uuid": self = .uuid
        case "uuidSwappedTime": self = .uuidSwappedTime
        case "unixTimestamp": self = .unixTimestamp
        case "unixTimestampMillis": self = .unixTimestampMillis
        case "json": self = .json
        case "phpSerialized": self = .phpSerialized
        case "messagePack": self = .messagePack
        case "protobuf": self = .protobuf
        case "igbinary": self = .igbinary
        default:
            if rawValue.hasPrefix(Self.avroPrefix) {
                let schemaID = String(rawValue.dropFirst(Self.avroPrefix.count))
                guard AvroSchemaStore.isSchemaID(schemaID) else { return nil }
                self = .avro(schemaID: schemaID)
            } else if rawValue.hasPrefix(Self.protobufSchemaPrefix) {
                let parts = rawValue.dropFirst(Self.protobufSchemaPrefix.count).split(separator: ":", maxSplits: 1)
                guard parts.count == 2, AvroSchemaStore.isSchemaID(String(parts[0])), !parts[1].isEmpty else { return nil }
                self = .protobufSchema(schemaID: String(parts[0]), message: String(parts[1]))
            } else if rawValue.hasPrefix(Self.schemaRegistryPrefix),
                      let connectionID = UUID(uuidString: String(rawValue.dropFirst(Self.schemaRegistryPrefix.count))) {
                self = .schemaRegistry(connectionID: connectionID)
            } else {
                return nil
            }
        }
    }

    var rawValue: String {
        switch self {
        case .raw: return "raw"
        case .text: return "text"
        case .uuid: return "uuid"
        case .uuidSwappedTime: return "uuidSwappedTime"
        case .unixTimestamp: return "unixTimestamp"
        case .unixTimestampMillis: return "unixTimestampMillis"
        case .json: return "json"
        case .phpSerialized: return "phpSerialized"
        case .messagePack: return "messagePack"
        case .protobuf: return "protobuf"
        case .igbinary: return "igbinary"
        case .avro(let schemaID): return Self.avroPrefix + schemaID
        case .protobufSchema(let schemaID, let message): return Self.protobufSchemaPrefix + schemaID + ":" + message
        case .schemaRegistry(let connectionID): return Self.schemaRegistryPrefix + connectionID.uuidString
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let format = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown display format \(rawValue)")
        }
        self = format
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw: return String(localized: "Raw Value")
        case .text: return String(localized: "Text")
        case .uuid: return String(localized: "UUID")
        case .uuidSwappedTime: return String(localized: "UUID (Swapped Time)")
        case .unixTimestamp: return String(localized: "Unix Timestamp (seconds)")
        case .unixTimestampMillis: return String(localized: "Unix Timestamp (milliseconds)")
        case .json: return String(localized: "JSON")
        case .phpSerialized: return String(localized: "PHP Serialized")
        case .messagePack, .protobuf, .igbinary: return binaryValueFormat?.displayName ?? rawValue
        case .avro(let schemaID):
            guard let name = AvroSchemaStore.shared.schema(id: schemaID)?.displayName else { return "Avro" }
            return String(format: String(localized: "Avro (%@)"), name)
        case .protobufSchema(_, let message):
            return String(format: String(localized: "Protobuf (%@)"), message.split(separator: ".").last.map(String.init) ?? message)
        case .schemaRegistry:
            return String(localized: "Schema Registry")
        }
    }

    var binaryValueFormat: BinaryValueFormat? {
        switch self {
        case .messagePack: return .messagePack
        case .protobuf: return .protobuf
        case .igbinary: return .igbinary
        case .avro(let schemaID): return .avro(schemaID: schemaID)
        case .protobufSchema(let schemaID, let message): return .protobufSchema(schemaID: schemaID, message: message)
        case .schemaRegistry(let connectionID): return .schemaRegistry(connectionID: connectionID)
        case .raw, .text, .uuid, .uuidSwappedTime, .unixTimestamp, .unixTimestampMillis, .json, .phpSerialized:
            return nil
        }
    }

    var applicableColumnTypes: Set<String> {
        switch self {
        case .raw:
            return []
        case .text, .uuidSwappedTime, .messagePack, .protobuf, .igbinary, .avro, .protobufSchema:
            return ["blob"]
        // A framed value whose payload happens to be UTF-8 lands in a text column.
        case .schemaRegistry:
            return ["blob", "text"]
        case .uuid:
            return ["blob", "text"]
        case .unixTimestamp, .unixTimestampMillis:
            return ["integer"]
        case .json, .phpSerialized:
            return ["text"]
        }
    }

    func isApplicable(to columnType: ColumnType?, databaseType: DatabaseType? = nil) -> Bool {
        if self == .raw { return true }
        guard let columnType else { return false }

        let typeKey: String
        switch columnType {
        case .blob: typeKey = "blob"
        case .text: typeKey = "text"
        case .integer: typeKey = "integer"
        default: return false
        }

        if self == .uuid || self == .uuidSwappedTime, databaseType == .mongodb, columnType.isBlobType {
            return false
        }
        return applicableColumnTypes.contains(typeKey)
    }

    // A binary column is worth searching exactly when one of these is on it; hex is not what anyone types into Find.
    var rendersBinaryAsText: Bool {
        switch self {
        case .text, .uuid, .uuidSwappedTime, .messagePack, .protobuf, .igbinary, .avro, .protobufSchema, .schemaRegistry:
            return true
        case .raw, .unixTimestamp, .unixTimestampMillis, .json, .phpSerialized:
            return false
        }
    }

    static func applicableFormats(
        for columnType: ColumnType?,
        databaseType: DatabaseType? = nil
    ) -> [ValueDisplayFormat] {
        presetFormats.filter { $0.isApplicable(to: columnType, databaseType: databaseType) }
    }

    static func offersAvro(for columnType: ColumnType?, databaseType: DatabaseType? = nil) -> Bool {
        avro(schemaID: "").isApplicable(to: columnType, databaseType: databaseType)
    }

    static func offersProtobufSchema(for columnType: ColumnType?, databaseType: DatabaseType? = nil) -> Bool {
        protobufSchema(schemaID: "", message: "").isApplicable(to: columnType, databaseType: databaseType)
    }
}

enum ValueDisplayFormatColumnKey {
    static func storageKeys(for columns: [String]) -> [String] {
        let counts = columns.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var occurrences: [String: Int] = [:]

        return columns.map { name in
            let occurrence = occurrences[name, default: 0]
            occurrences[name] = occurrence + 1
            guard counts[name, default: 0] > 1 else { return name }
            return "\u{0}column:\(occurrence):\(name)"
        }
    }
}

//
//  ValueDisplayFormat.swift
//  TablePro
//
//  Semantic display formats for raw database values.
//  Enables auto-detection and per-column overrides for values like
//  UUIDs stored in BINARY(16) or Unix timestamps in INT columns.
//

import Foundation

enum ValueDisplayFormat: Hashable, Codable, CaseIterable, Identifiable, RawRepresentable {
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
    // The schema lives in AvroSchemaLibrary; the format carries its ID so every per-column path can decode.
    case avro(schemaID: String)

    private static let avroPrefix = "avro:"

    static let allCases: [ValueDisplayFormat] = [
        .raw, .text, .uuid, .uuidSwappedTime, .unixTimestamp, .unixTimestampMillis, .json, .phpSerialized,
        .messagePack, .protobuf, .igbinary
    ]

    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.avroPrefix) {
            let schemaID = String(rawValue.dropFirst(Self.avroPrefix.count))
            guard !schemaID.isEmpty else { return nil }
            self = .avro(schemaID: schemaID)
            return
        }
        guard let format = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = format
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
            guard let name = AvroSchemaLibrary.shared.name(id: schemaID) else { return "Avro" }
            return String(format: String(localized: "Avro (%@)"), name)
        }
    }

    var binaryValueFormat: BinaryValueFormat? {
        switch self {
        case .messagePack: return .messagePack
        case .protobuf: return .protobuf
        case .igbinary: return .igbinary
        case .avro(let schemaID): return .avro(schemaID: schemaID)
        case .raw, .text, .uuid, .uuidSwappedTime, .unixTimestamp, .unixTimestampMillis, .json, .phpSerialized:
            return nil
        }
    }

    /// Column types this format can apply to.
    var applicableColumnTypes: Set<String> {
        switch self {
        case .raw:
            return []
        case .text, .uuidSwappedTime, .messagePack, .protobuf, .igbinary, .avro:
            return ["blob"]
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

    /// Whether this format turns stored bytes into readable characters. A binary column is worth
    /// searching exactly when one of these is on it; hex is not what anyone types into Find.
    var rendersBinaryAsText: Bool {
        switch self {
        case .text, .uuid, .uuidSwappedTime, .messagePack, .protobuf, .igbinary, .avro:
            return true
        case .raw, .unixTimestamp, .unixTimestampMillis, .json, .phpSerialized:
            return false
        }
    }

    /// Returns applicable formats for a given column type.
    /// Always includes `.raw` as the first option. Avro is not listed: it needs a schema chosen first.
    static func applicableFormats(
        for columnType: ColumnType?,
        databaseType: DatabaseType? = nil
    ) -> [ValueDisplayFormat] {
        allCases.filter { $0.isApplicable(to: columnType, databaseType: databaseType) }
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

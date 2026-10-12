import Foundation

/// One Firestore value, decoded from and encoded to the REST `Value` message.
public indirect enum FirestoreValue: Sendable, Hashable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case double(Double)
    /// RFC 3339 text exactly as the server sent it, so microseconds survive a round trip.
    case timestamp(String)
    case string(String)
    case bytes(Data)
    /// A document path relative to `.../documents`, such as `users/alice`.
    case reference(String)
    case geoPoint(latitude: Double, longitude: Double)
    case array([FirestoreValue])
    case map([String: FirestoreValue])

    public var typeName: String {
        switch self {
        case .null: return FirestoreTypeName.null
        case .boolean: return FirestoreTypeName.boolean
        case .integer: return FirestoreTypeName.integer
        case .double: return FirestoreTypeName.double
        case .timestamp: return FirestoreTypeName.timestamp
        case .string: return FirestoreTypeName.string
        case .bytes: return FirestoreTypeName.bytes
        case .reference: return FirestoreTypeName.reference
        case .geoPoint: return FirestoreTypeName.geoPoint
        case .array: return FirestoreTypeName.array
        case .map: return FirestoreTypeName.map
        }
    }
}

public enum FirestoreTypeName {
    public static let null = "null"
    public static let boolean = "boolean"
    public static let integer = "integer"
    public static let double = "double"
    public static let timestamp = "timestamp"
    public static let string = "string"
    public static let bytes = "bytes"
    public static let reference = "reference"
    public static let geoPoint = "geopoint"
    public static let array = "array"
    public static let map = "map"

    public static let all = [string, integer, double, boolean, timestamp, map, array, reference, geoPoint, bytes, null]
}

// MARK: - REST wire format

public extension FirestoreValue {
    /// `documentRoot` is `projects/<p>/databases/<d>/documents`, which a reference carries in full
    /// on the wire and which the grid leaves off.
    init(rest json: FirebaseJSON, documentRoot: String) throws {
        guard case .object(let members) = json, let (key, payload) = members.first, members.count == 1 else {
            throw FirebaseError.malformedResponse(String(localized: "Firestore sent a value with no type."))
        }
        switch key {
        case "nullValue":
            self = .null
        case "booleanValue":
            guard case .bool(let value) = payload else { throw Self.malformed(key) }
            self = .boolean(value)
        case "integerValue":
            self = .integer(try Self.int64(payload, key: key))
        case "doubleValue":
            self = .double(try Self.double(payload, key: key))
        case "timestampValue":
            guard let text = payload.stringValue else { throw Self.malformed(key) }
            self = .timestamp(text)
        case "stringValue":
            guard let text = payload.stringValue else { throw Self.malformed(key) }
            self = .string(text)
        case "bytesValue":
            guard let text = payload.stringValue, let data = Data(base64Encoded: text) else {
                throw Self.malformed(key)
            }
            self = .bytes(data)
        case "referenceValue":
            guard let text = payload.stringValue else { throw Self.malformed(key) }
            self = .reference(FirestorePath.relative(text, documentRoot: documentRoot))
        case "geoPointValue":
            self = .geoPoint(
                latitude: try Self.double(payload["latitude"] ?? .double(0), key: key),
                longitude: try Self.double(payload["longitude"] ?? .double(0), key: key)
            )
        case "arrayValue":
            let values = payload["values"]?.arrayValue ?? []
            self = .array(try values.map { try FirestoreValue(rest: $0, documentRoot: documentRoot) })
        case "mapValue":
            let fields = payload["fields"]?.objectValue ?? [:]
            self = .map(try fields.mapValues { try FirestoreValue(rest: $0, documentRoot: documentRoot) })
        default:
            throw FirebaseError.malformedResponse(
                String(format: String(localized: "Firestore sent a value of unknown type %@."), key)
            )
        }
    }

    func rest(documentRoot: String) -> FirebaseJSON {
        switch self {
        case .null:
            return .object(["nullValue": .null])
        case .boolean(let value):
            return .object(["booleanValue": .bool(value)])
        case .integer(let value):
            return .object(["integerValue": .string(String(value))])
        case .double(let value):
            return .object(["doubleValue": Self.restDouble(value)])
        case .timestamp(let text):
            return .object(["timestampValue": .string(text)])
        case .string(let text):
            return .object(["stringValue": .string(text)])
        case .bytes(let data):
            return .object(["bytesValue": .string(data.base64EncodedString())])
        case .reference(let path):
            return .object(["referenceValue": .string(FirestorePath.absolute(path, documentRoot: documentRoot))])
        case .geoPoint(let latitude, let longitude):
            return .object(["geoPointValue": .object([
                "latitude": .double(latitude), "longitude": .double(longitude)
            ])])
        case .array(let values):
            return .object(["arrayValue": .object([
                "values": .array(values.map { $0.rest(documentRoot: documentRoot) })
            ])])
        case .map(let fields):
            return .object(["mapValue": .object([
                "fields": .object(fields.mapValues { $0.rest(documentRoot: documentRoot) })
            ])])
        }
    }

    /// The REST API reads NaN and the infinities only as the strings it writes them as.
    private static func restDouble(_ value: Double) -> FirebaseJSON {
        guard value.isFinite else {
            return .string(value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity"))
        }
        return .double(value)
    }

    private static func int64(_ json: FirebaseJSON, key: String) throws -> Int64 {
        switch json {
        case .string(let text):
            guard let value = Int64(text) else { throw malformed(key) }
            return value
        case .int(let value):
            return value
        default:
            throw malformed(key)
        }
    }

    private static func double(_ json: FirebaseJSON, key: String) throws -> Double {
        switch json {
        case .double(let value): return value
        case .int(let value): return Double(value)
        case .string("NaN"): return .nan
        case .string("Infinity"): return .infinity
        case .string("-Infinity"): return -.infinity
        default: throw malformed(key)
        }
    }

    private static func malformed(_ key: String) -> FirebaseError {
        .malformedResponse(String(format: String(localized: "Firestore sent a malformed %@."), key))
    }
}

public enum FirestorePath {
    public static func relative(_ name: String, documentRoot: String) -> String {
        let prefix = documentRoot + "/"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    public static func absolute(_ path: String, documentRoot: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasPrefix("projects/") {
            return trimmed
        }
        return trimmed.isEmpty ? documentRoot : documentRoot + "/" + trimmed
    }

    /// A path with an even number of segments names a document, an odd number a collection.
    public static func isDocument(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        return !segments.isEmpty && segments.count.isMultiple(of: 2)
    }

    public static func lastSegment(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// The parent of a collection path: the root for `users`, the document for `users/a/orders`.
    public static func split(collectionPath: String) -> (parent: String, collectionId: String) {
        var segments = collectionPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let collectionId = segments.popLast() ?? ""
        return (segments.joined(separator: "/"), collectionId)
    }
}

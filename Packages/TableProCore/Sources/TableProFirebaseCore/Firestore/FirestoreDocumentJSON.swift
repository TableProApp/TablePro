import Foundation

/// The JSON a user reads and edits for a Firestore document. Plain JSON covers strings, booleans,
/// integers, maps and arrays; the types JSON has no word for are single-key objects:
///
///     {"$timestamp": "2026-10-12T08:00:00Z"}   {"$ref": "users/alice"}
///     {"$geo": {"latitude": 45.4, "longitude": 9.2}}   {"$bytes": "aGk="}   {"$double": 3}
///
/// `$double` is needed only for a double with no fraction, which plain JSON would read back as an
/// integer. A real map whose only key is one of these tags is written inside `{"$map": {...}}`.
public enum FirestoreDocumentJSON {
    static let timestampTag = "$timestamp"
    static let referenceTag = "$ref"
    static let geoTag = "$geo"
    static let bytesTag = "$bytes"
    static let doubleTag = "$double"
    static let mapTag = "$map"
    static let tags: Set<String> = [timestampTag, referenceTag, geoTag, bytesTag, doubleTag, mapTag]

    public static func json(_ value: FirestoreValue) -> FirebaseJSON {
        switch value {
        case .null:
            return .null
        case .boolean(let flag):
            return .bool(flag)
        case .integer(let number):
            return .int(number)
        case .double(let number):
            guard number.isFinite, number.rounded() != number else {
                return .object([doubleTag: number.isFinite ? .double(number) : .string(doubleWord(number))])
            }
            return .double(number)
        case .timestamp(let text):
            return .object([timestampTag: .string(text)])
        case .string(let text):
            return .string(text)
        case .bytes(let data):
            return .object([bytesTag: .string(data.base64EncodedString())])
        case .reference(let path):
            return .object([referenceTag: .string(path)])
        case .geoPoint(let latitude, let longitude):
            return .object([geoTag: .object(["latitude": .double(latitude), "longitude": .double(longitude)])])
        case .array(let values):
            return .array(values.map(json))
        case .map(let fields):
            let members = fields.mapValues(json)
            if members.count == 1, let key = members.keys.first, tags.contains(key) {
                return .object([mapTag: .object(members)])
            }
            return .object(members)
        }
    }

    public static func text(fields: [String: FirestoreValue]) -> String {
        FirebaseJSON.object(fields.mapValues(json)).text(pretty: true)
    }

    public static func value(_ json: FirebaseJSON) throws -> FirestoreValue {
        switch json {
        case .null:
            return .null
        case .bool(let flag):
            return .boolean(flag)
        case .int(let number):
            return .integer(number)
        case .double(let number):
            return .double(number)
        case .string(let text):
            return .string(text)
        case .array(let values):
            return .array(try values.map(value))
        case .object(let members):
            if members.count == 1, let (key, payload) = members.first, tags.contains(key) {
                return try tagged(key, payload)
            }
            return .map(try members.mapValues(value))
        }
    }

    /// Reads the top level of an edited document, which has to be an object of fields.
    public static func fields(from text: String) throws -> [String: FirestoreValue] {
        let json = try FirebaseJSON.parse(text)
        guard case .object(let members) = json else {
            throw FirebaseError.configuration(String(localized: "A Firestore document is a JSON object of fields."))
        }
        return try members.mapValues(value)
    }

    private static func tagged(_ tag: String, _ payload: FirebaseJSON) throws -> FirestoreValue {
        switch tag {
        case timestampTag:
            guard let text = payload.stringValue, FirestoreTimestamp.isValid(text) else {
                throw invalid(tag, String(localized: "an RFC 3339 time such as 2026-10-12T08:00:00Z"))
            }
            return .timestamp(text)
        case referenceTag:
            guard let path = payload.stringValue, FirestorePath.isDocument(path) else {
                throw invalid(tag, String(localized: "a document path such as users/alice"))
            }
            return .reference(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        case geoTag:
            guard let latitude = number(payload["latitude"]), let longitude = number(payload["longitude"]),
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw invalid(tag, String(localized: "an object with latitude and longitude"))
            }
            return .geoPoint(latitude: latitude, longitude: longitude)
        case bytesTag:
            guard let text = payload.stringValue, let data = Data(base64Encoded: text) else {
                throw invalid(tag, String(localized: "base64 text"))
            }
            return .bytes(data)
        case doubleTag:
            if let number = number(payload) { return .double(number) }
            switch payload.stringValue {
            case "NaN": return .double(.nan)
            case "Infinity": return .double(.infinity)
            case "-Infinity": return .double(-.infinity)
            default: throw invalid(tag, String(localized: "a number"))
            }
        default:
            guard case .object(let members) = payload else {
                throw invalid(tag, String(localized: "an object"))
            }
            return .map(try members.mapValues(value))
        }
    }

    private static func number(_ json: FirebaseJSON?) -> Double? {
        switch json {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    private static func doubleWord(_ value: Double) -> String {
        value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity")
    }

    private static func invalid(_ tag: String, _ expected: String) -> FirebaseError {
        .configuration(String(format: String(localized: "%@ needs %@."), tag, expected))
    }
}

public enum FirestoreTimestamp {
    private static let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$"#

    public static func isValid(_ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

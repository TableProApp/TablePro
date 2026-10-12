import Foundation

/// A Firestore value as a grid cell, and a cell edit back as a value. The grid only holds text, so
/// an edit is read by the type the field already had; a string field stays a string even when the
/// new text looks like a number.
public enum FirestoreCell {
    public enum Display: Sendable, Equatable {
        case null
        case text(String)
        case bytes(Data)
    }

    public static func display(_ value: FirestoreValue) -> Display {
        switch value {
        case .null:
            return .null
        case .boolean(let flag):
            return .text(flag ? "true" : "false")
        case .integer(let number):
            return .text(String(number))
        case .double(let number):
            return .text(doubleText(number))
        case .timestamp(let text), .string(let text), .reference(let text):
            return .text(text)
        case .bytes(let data):
            return .bytes(data)
        case .geoPoint(let latitude, let longitude):
            return .text("\(doubleText(latitude)), \(doubleText(longitude))")
        case .array, .map:
            return .text(FirestoreDocumentJSON.json(value).text())
        }
    }

    /// `typeName` is the type the field held before the edit, or nil for a field the row did not
    /// have, in which case the text is read as a JSON literal and falls back to a string.
    public static func value(text: String, typeName: String?) throws -> FirestoreValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch typeName {
        case FirestoreTypeName.string:
            return .string(text)
        case FirestoreTypeName.integer:
            guard let number = Int64(trimmed) else { throw mismatch(text, FirestoreTypeName.integer) }
            return .integer(number)
        case FirestoreTypeName.double:
            guard let number = Double(trimmed) else { throw mismatch(text, FirestoreTypeName.double) }
            return .double(number)
        case FirestoreTypeName.boolean:
            switch trimmed.lowercased() {
            case "true", "1": return .boolean(true)
            case "false", "0": return .boolean(false)
            default: throw mismatch(text, FirestoreTypeName.boolean)
            }
        case FirestoreTypeName.timestamp:
            guard FirestoreTimestamp.isValid(trimmed) else { throw mismatch(text, FirestoreTypeName.timestamp) }
            return .timestamp(trimmed)
        case FirestoreTypeName.reference:
            guard FirestorePath.isDocument(trimmed) else { throw mismatch(text, FirestoreTypeName.reference) }
            return .reference(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        case FirestoreTypeName.geoPoint:
            return try geoPoint(trimmed, original: text)
        case FirestoreTypeName.bytes:
            guard let data = Data(base64Encoded: trimmed) else { throw mismatch(text, FirestoreTypeName.bytes) }
            return .bytes(data)
        case FirestoreTypeName.map, FirestoreTypeName.array:
            return try FirestoreDocumentJSON.value(FirebaseJSON.parse(trimmed))
        default:
            return inferred(text)
        }
    }

    public static func value(bytes: Data) -> FirestoreValue {
        .bytes(bytes)
    }

    public static func inferred(_ text: String) -> FirestoreValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, "{[-0123456789tfn".contains(first),
              let json = try? FirebaseJSON.parse(trimmed),
              let value = try? FirestoreDocumentJSON.value(json) else {
            return .string(text)
        }
        if case .string = value { return .string(text) }
        return value
    }

    /// The type most cells in a column hold, ignoring missing fields and nulls, so a column of
    /// strings with one stray null still edits as strings.
    public static func dominantType(_ values: [FirestoreValue?]) -> String {
        var counts: [String: Int] = [:]
        for case let value? in values where value != .null {
            counts[value.typeName, default: 0] += 1
        }
        let best = counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }
        return best?.key ?? (values.contains { $0 == .null } ? FirestoreTypeName.null : FirestoreTypeName.string)
    }

    static func doubleText(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity") }
        return "\(value)"
    }

    private static func geoPoint(_ trimmed: String, original: String) throws -> FirestoreValue {
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]),
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw mismatch(original, FirestoreTypeName.geoPoint)
        }
        return .geoPoint(latitude: latitude, longitude: longitude)
    }

    private static func mismatch(_ text: String, _ typeName: String) -> FirebaseError {
        let example: String
        switch typeName {
        case FirestoreTypeName.timestamp: example = "2026-10-12T08:00:00Z"
        case FirestoreTypeName.reference: example = "users/alice"
        case FirestoreTypeName.geoPoint: example = "45.46, 9.19"
        case FirestoreTypeName.boolean: example = "true"
        default: example = typeName
        }
        return .configuration(String(
            format: String(localized: "\"%@\" is not a valid %@. Example: %@"), text, typeName, example
        ))
    }
}

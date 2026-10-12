import Foundation

/// A JSON value that keeps integers and doubles apart. Firestore stores `1` and `1.0` as different
/// types, and a Realtime Database node edited as `1` must not come back as `1.0`.
public indirect enum FirebaseJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([FirebaseJSON])
    case object([String: FirebaseJSON])

    public static func parse(_ data: Data) throws -> FirebaseJSON {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw FirebaseError.malformedResponse(String(localized: "The text is not valid JSON."))
        }
        return FirebaseJSON(foundation: object)
    }

    public static func parse(_ text: String) throws -> FirebaseJSON {
        try parse(Data(text.utf8))
    }

    public init(foundation object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            self = FirebaseJSON(number: number)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(FirebaseJSON.init(foundation:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(FirebaseJSON.init(foundation:)))
        default:
            self = .null
        }
    }

    private init(number: NSNumber) {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
            return
        }
        switch CFNumberGetType(number) {
        case .float32Type, .float64Type, .floatType, .doubleType, .cgFloatType:
            self = .double(number.doubleValue)
        default:
            self = .int(number.int64Value)
        }
    }

    public var objectValue: [String: FirebaseJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [FirebaseJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> FirebaseJSON? {
        objectValue?[key]
    }

    /// Keys are written sorted, so two equal values always produce the same text and an edit can be
    /// compared against what was fetched.
    public func text(pretty: Bool = false) -> String {
        var output = ""
        write(into: &output, pretty: pretty, indent: 0)
        return output
    }

    public func data() -> Data {
        Data(text().utf8)
    }

    private func write(into output: inout String, pretty: Bool, indent: Int) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .int(let value):
            output += String(value)
        case .double(let value):
            output += Self.doubleText(value)
        case .string(let value):
            Self.writeString(value, into: &output)
        case .array(let values):
            writeArray(values, into: &output, pretty: pretty, indent: indent)
        case .object(let members):
            writeObject(members, into: &output, pretty: pretty, indent: indent)
        }
    }

    private func writeArray(_ values: [FirebaseJSON], into output: inout String, pretty: Bool, indent: Int) {
        guard !values.isEmpty else {
            output += "[]"
            return
        }
        output += "["
        for (index, value) in values.enumerated() {
            if index > 0 { output += "," }
            if pretty { output += "\n" + String(repeating: "  ", count: indent + 1) }
            value.write(into: &output, pretty: pretty, indent: indent + 1)
        }
        if pretty { output += "\n" + String(repeating: "  ", count: indent) }
        output += "]"
    }

    private func writeObject(
        _ members: [String: FirebaseJSON],
        into output: inout String,
        pretty: Bool,
        indent: Int
    ) {
        guard !members.isEmpty else {
            output += "{}"
            return
        }
        output += "{"
        for (index, key) in members.keys.sorted().enumerated() {
            if index > 0 { output += "," }
            if pretty { output += "\n" + String(repeating: "  ", count: indent + 1) }
            Self.writeString(key, into: &output)
            output += pretty ? ": " : ":"
            members[key]?.write(into: &output, pretty: pretty, indent: indent + 1)
        }
        if pretty { output += "\n" + String(repeating: "  ", count: indent) }
        output += "}"
    }

    /// JSON has no NaN or infinity, so those are written as strings; the caller that needs them
    /// back as numbers wraps them in a tag of its own.
    static func doubleText(_ value: Double) -> String {
        guard value.isFinite else {
            return value.isNaN ? "\"NaN\"" : (value > 0 ? "\"Infinity\"" : "\"-Infinity\"")
        }
        if value.rounded() == value, abs(value) < 1e16 {
            return String(format: "%.1f", value)
        }
        return "\(value)"
    }

    static func writeString(_ value: String, into output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}

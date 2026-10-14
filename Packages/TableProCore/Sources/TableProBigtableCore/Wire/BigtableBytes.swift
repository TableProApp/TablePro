import Foundation

/// Row keys, qualifiers and values are bytes. Text that is valid UTF-8 with no control characters
/// shows as itself; anything else shows as `b64:` followed by base64, which reads back to the same
/// bytes, so a binary key can still be named in a request line and edited from the grid.
public enum BigtableBytes {
    public static let base64Prefix = "b64:"

    public static func display(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), isPrintable(text), !text.hasPrefix(base64Prefix) {
            return text
        }
        return base64Prefix + data.base64EncodedString()
    }

    public static func parse(_ text: String) throws -> Data {
        guard text.hasPrefix(base64Prefix) else { return Data(text.utf8) }
        guard let data = Data(base64Encoded: String(text.dropFirst(base64Prefix.count))) else {
            throw BigtableError.configuration(String(format: String(localized: "\"%@\" is not valid base64."), text))
        }
        return data
    }

    public static func isPrintable(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            scalar.value < 0x20 && scalar != "\t" && scalar != "\n" || scalar.value == 0x7F
        }
    }

    static func decodeBase64(_ text: String?) throws -> Data {
        guard let text else { return Data() }
        guard let data = Data(base64Encoded: text) else {
            throw BigtableError.malformedResponse(String(localized: "Bigtable sent bytes that are not base64."))
        }
        return data
    }

    /// The smallest key greater than every key starting with `prefix`: the prefix with its last
    /// byte below 0xFF incremented and what follows dropped. Nil when every byte is 0xFF, which
    /// leaves the range open at the end.
    public static func prefixEnd(_ prefix: Data) -> Data? {
        var bytes = [UInt8](prefix)
        while let last = bytes.last {
            if last < 0xFF {
                bytes[bytes.count - 1] = last + 1
                return Data(bytes)
            }
            bytes.removeLast()
        }
        return nil
    }

    /// `regexLiteral` writes only printable ASCII, so its text form always exists.
    public static func regexText(_ data: Data) -> String {
        String(bytes: regexLiteral(data), encoding: .ascii) ?? ""
    }

    /// RE2 reads these as operators, so a literal is escaped byte by byte before it goes into a
    /// regex filter.
    public static func regexLiteral(_ data: Data) -> Data {
        let special = Set("\\^$.|?*+()[]{}".utf8)
        var escaped = Data()
        for byte in data {
            if special.contains(byte) {
                escaped.append(UInt8(ascii: "\\"))
                escaped.append(byte)
            } else if byte < 0x20 || byte >= 0x7F {
                escaped.append(contentsOf: Array(String(format: "\\x%02X", byte).utf8))
            } else {
                escaped.append(byte)
            }
        }
        return escaped
    }
}

import Foundation

/// Row keys, qualifiers and values are bytes. Text that is valid UTF-8 with no control characters
/// shows as itself; anything else, and text that itself starts with `b64:`, shows as `b64:` and
/// base64, which reads back to the same bytes.
public enum BigtableBytes {
    public static let base64Prefix = "b64:"

    public static func display(_ data: Data) -> String {
        if let text = printableText(data) {
            return text
        }
        return base64Prefix + data.base64EncodedString()
    }

    /// The bytes as text when `display` would show them as themselves.
    public static func printableText(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), isPrintable(text), !text.hasPrefix(base64Prefix) else {
            return nil
        }
        return text
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

    static func decodeBase64(_ text: String) throws -> Data {
        guard let data = Data(base64Encoded: text) else {
            throw BigtableError.malformedResponse(String(localized: "Bigtable sent bytes that are not base64."))
        }
        return data
    }

    /// The smallest key greater than every key starting with `prefix`. Nil when every byte is 0xFF,
    /// which leaves the range open at the end.
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

    public static func regexText(_ data: Data) -> String {
        String(bytes: regexLiteral(data), encoding: .ascii) ?? ""
    }

    /// Escapes RE2 operators byte by byte and writes every other byte outside printable ASCII as
    /// `\xNN`, so the result is always ASCII.
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

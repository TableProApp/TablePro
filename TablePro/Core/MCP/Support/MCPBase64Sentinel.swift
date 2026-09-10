import Foundation

public enum MCPBase64Sentinel {
    public static let prefix = "=?base64?"
    public static let suffix = "?="

    public static func isSentinel(_ value: String) -> Bool {
        guard value.utf8.count >= prefix.utf8.count + suffix.utf8.count else { return false }
        return value.hasPrefix(prefix) && value.hasSuffix(suffix)
    }

    public static func isHeaderSafe(_ value: String) -> Bool {
        guard !isSentinel(value) else { return false }
        guard value.first != " ", value.last != " ", value.first != "\t", value.last != "\t" else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value <= 0x7E)
        }
    }

    public static func encode(_ value: String) -> String {
        prefix + Data(value.utf8).base64EncodedString() + suffix
    }

    public static func encodeIfNeeded(_ value: String) -> String {
        isHeaderSafe(value) ? value : encode(value)
    }

    public static func decode(_ value: String) -> String? {
        guard isSentinel(value) else { return nil }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        let payload = String(value[start..<end])
        guard let data = Data(base64Encoded: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodeIfNeeded(_ value: String) -> String? {
        isSentinel(value) ? decode(value) : value
    }
}

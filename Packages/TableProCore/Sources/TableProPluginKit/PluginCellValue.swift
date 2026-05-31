import Foundation

public enum PluginCellValue: Sendable, Hashable {
    case null
    case text(String)
    case bytes(Data)
}

extension PluginCellValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .text(value)
    }
}

extension PluginCellValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

public extension PluginCellValue {
    static func fromOptional(_ string: String?) -> PluginCellValue {
        string.map(PluginCellValue.text) ?? .null
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var asText: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var asBytes: Data? {
        if case .bytes(let value) = self { return value }
        return nil
    }

    var asAny: Any? {
        switch self {
        case .null: return nil
        case .text(let s): return s
        case .bytes(let d): return d
        }
    }

    /// String representation suitable for sorting and equality comparison.
    /// Binary cells are rendered as uppercase hex without prefix so byte-wise
    /// lexicographic order matches a stable sort across runs.
    var sortKey: String {
        switch self {
        case .null: return ""
        case .text(let s): return s
        case .bytes(let d):
            var hex = ""
            hex.reserveCapacity(d.count * 2)
            for byte in d {
                hex += String(format: "%02X", byte)
            }
            return hex
        }
    }
}

extension PluginCellValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case null
        case text
        case bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .null:
            self = .null
        case .text:
            self = .text(try container.decode(String.self, forKey: .value))
        case .bytes:
            self = .bytes(try container.decode(Data.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode(Kind.null, forKey: .kind)
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .bytes(let value):
            try container.encode(Kind.bytes, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

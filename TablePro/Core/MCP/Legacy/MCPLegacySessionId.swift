import Foundation

public struct MCPLegacySessionId: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> MCPLegacySessionId {
        var characters = ""
        characters.reserveCapacity(entropyByteCount * 2)
        for _ in 0 ..< entropyByteCount {
            let byte = UInt8.random(in: UInt8.min ... UInt8.max)
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0F)])
        }
        return MCPLegacySessionId(characters)
    }

    public var isWellFormed: Bool {
        guard !rawValue.isEmpty, rawValue.utf8.count <= Self.maximumByteCount else { return false }
        return rawValue.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    public var redacted: String {
        String(rawValue.prefix(Self.redactedPrefixLength))
    }

    public var description: String {
        rawValue
    }

    private static let entropyByteCount = 32
    private static let maximumByteCount = 512
    private static let redactedPrefixLength = 8
    private static let hexDigits = Array("0123456789abcdef")
}

import Foundation

public struct KafkaUUID: Hashable, Sendable {
    public let bytes: [UInt8]

    public static let zero = KafkaUUID(bytes: [UInt8](repeating: 0, count: 16))

    public init(bytes: [UInt8]) {
        self.bytes = bytes.count == 16 ? bytes : [UInt8](repeating: 0, count: 16)
    }

    public var isZero: Bool { bytes.allSatisfy { $0 == 0 } }

    public var uuidString: String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let groups = [0 ..< 8, 8 ..< 12, 12 ..< 16, 16 ..< 20, 20 ..< 32]
        return groups
            .map { String(hex[hex.index(hex.startIndex, offsetBy: $0.lowerBound) ..< hex.index(hex.startIndex, offsetBy: $0.upperBound)]) }
            .joined(separator: "-")
    }
}

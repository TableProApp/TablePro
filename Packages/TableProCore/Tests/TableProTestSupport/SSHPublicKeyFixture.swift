import Foundation

// Builds the wire encodings a `.pub` file and the agent protocol carry, so no fixture is a
// hand-typed base64 string that has to be trusted.
public enum SSHPublicKeyFixture {
    public static func wireString(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        let length = UInt32(bytes.count)
        return [
            UInt8(length >> 24 & 0xFF),
            UInt8(length >> 16 & 0xFF),
            UInt8(length >> 8 & 0xFF),
            UInt8(length & 0xFF),
        ] + bytes
    }

    public static func blob(type: String, seed: UInt8) -> Data {
        Data(wireString(type) + [UInt8](repeating: seed, count: 32))
    }

    public static func line(type: String, seed: UInt8, comment: String = "alice@example.com") -> String {
        "\(type) \(blob(type: type, seed: seed).base64EncodedString()) \(comment)"
    }
}

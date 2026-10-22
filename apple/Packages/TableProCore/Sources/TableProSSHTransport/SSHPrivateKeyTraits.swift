import Foundation

// openssh-key-v1 keeps the cipher name and the public key in the clear, so both read without the passphrase.
public struct SSHPrivateKeyTraits: Equatable, Sendable {
    public let keyType: String?
    public let isEncrypted: Bool

    public var isSecurityKey: Bool {
        keyType?.hasPrefix("sk-") ?? false
    }

    public init?(openSSH: String) {
        guard let begin = openSSH.range(of: Self.beginMarker),
              let end = openSSH.range(of: Self.endMarker, range: begin.upperBound..<openSSH.endIndex)
        else { return nil }
        let body = openSSH[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let decoded = Data(base64Encoded: String(body)) else { return nil }

        var reader = SSHWireReader(Array(decoded))
        guard reader.bytes(Self.magic.count)?.elementsEqual(Self.magic) == true,
              let cipher = reader.string(), !cipher.isEmpty
        else { return nil }

        isEncrypted = cipher != "none"
        keyType = Self.firstKeyType(after: &reader)
    }

    private static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let endMarker = "-----END OPENSSH PRIVATE KEY-----"
    private static let magic = Array("openssh-key-v1\0".utf8)

    // The KDF name and options sit between the cipher and the key count.
    private static func firstKeyType(after reader: inout SSHWireReader) -> String? {
        guard reader.field() != nil,
              reader.field() != nil,
              let keyCount = reader.uint32(), keyCount > 0,
              let publicKey = reader.field()
        else { return nil }
        var blob = SSHWireReader(Array(publicKey))
        return blob.string()
    }
}

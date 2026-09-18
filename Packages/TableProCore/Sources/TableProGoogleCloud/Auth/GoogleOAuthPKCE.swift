import CryptoKit
import Foundation
import Security

public struct GoogleOAuthPKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let state: String

    static let randomByteCount = 32

    public static func generate() -> GoogleOAuthPKCE {
        let verifier = GoogleBase64URL.encode(randomBytes(count: randomByteCount))
        return GoogleOAuthPKCE(
            verifier: verifier,
            challenge: challenge(for: verifier),
            state: GoogleBase64URL.encode(randomBytes(count: randomByteCount))
        )
    }

    public static func challenge(for verifier: String) -> String {
        GoogleBase64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            var generator = SystemRandomNumberGenerator()
            return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        }
        return Data(bytes)
    }
}

extension GoogleOAuthPKCE: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "GoogleOAuthPKCE(challenge: \(challenge), verifier: <redacted>, state: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

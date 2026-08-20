//
//  XAIPKCE.swift
//  TablePro
//

import CryptoKit
import Foundation
import Security

struct XAIPKCE: Sendable {
    let verifier: String
    let challenge: String
    let state: String

    init() {
        let verifier = Self.randomURLSafeString(byteCount: 32)
        self.verifier = verifier
        self.state = Self.randomURLSafeString(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = XAIBase64URL.encode(Data(digest))
    }

    static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
            }
        }
        return XAIBase64URL.encode(Data(bytes))
    }
}

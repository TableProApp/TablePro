//
//  LicenseSignatureVerifier.swift
//  TablePro
//

import Foundation
import os
import Security

// Checks the RSA signature of a payload an older build stored, until the key exchange retires it.
final class LicenseSignatureVerifier: @unchecked Sendable {
    static let shared = LicenseSignatureVerifier()

    private let publicKey: SecKey?

    private init() {
        self.publicKey = Self.loadPublicKey()
        if publicKey == nil {
            Logger(subsystem: "com.TablePro", category: "LicenseSignatureVerifier")
                .error("Failed to load license public key from app bundle")
        }
    }

    func verify(payload: SignedLicensePayload) throws -> LicensePayloadData {
        guard let publicKey = publicKey else {
            throw LicenseError.signatureInvalid
        }

        // The server signs json_encode($data, JSON_UNESCAPED_SLASHES) over a ksort'ed array.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let dataJSON = try encoder.encode(payload.data)

        guard let signatureData = Data(base64Encoded: payload.signature) else {
            throw LicenseError.signatureInvalid
        }

        let isValid = SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            dataJSON as CFData,
            signatureData as CFData,
            nil
        )

        guard isValid else {
            throw LicenseError.signatureInvalid
        }

        return payload.data
    }

    private static func loadPublicKey() -> SecKey? {
        guard let url = Bundle.main.url(forResource: "license_public", withExtension: "pem"),
              let pemString = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }

        return createSecKey(fromPEM: pemString)
    }

    private static func createSecKey(fromPEM pem: String) -> SecKey? {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let keyData = Data(base64Encoded: stripped) else {
            return nil
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2_048,
        ]

        return SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil)
    }
}

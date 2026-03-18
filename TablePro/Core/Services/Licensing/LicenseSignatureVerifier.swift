//
//  LicenseSignatureVerifier.swift
//  TablePro
//
//  RSA-SHA256 signature verification using Security framework + embedded public key
//

import Foundation
import os
import Security

/// Verifies RSA-SHA256 signatures on license payloads using the embedded public key
final class LicenseSignatureVerifier {
    static let shared = LicenseSignatureVerifier()

    private let publicKey: SecKey?

    private init() {
        self.publicKey = Self.loadPublicKey()
        if publicKey == nil {
            Logger(subsystem: "com.TablePro", category: "LicenseSignatureVerifier")
                .error("Failed to load license public key from app bundle")
        }
    }

    // MARK: - Public API

    /// Verify a signed license payload and return the decoded data if valid.
    /// Throws `LicenseError.signatureInvalid` if the signature doesn't match.
    func verify(payload: SignedLicensePayload) throws -> LicensePayloadData {
        guard let publicKey = publicKey else {
            throw LicenseError.signatureInvalid
        }

        // Encode the data portion as canonical JSON (same as server)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let dataJSON = try encoder.encode(payload.data)

        // Decode the base64 signature
        guard let signatureData = Data(base64Encoded: payload.signature) else {
            throw LicenseError.signatureInvalid
        }

        // Verify RSA-SHA256 signature
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

    // MARK: - Key Loading

    /// Load the RSA public key from the app bundle's PEM file
    private static func loadPublicKey() -> SecKey? {
        guard let url = Bundle.main.url(forResource: "license_public", withExtension: "pem"),
              let pemString = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }

        return createSecKey(fromPEM: pemString)
    }

    /// Parse a PEM-encoded public key into a SecKey
    private static func createSecKey(fromPEM pem: String) -> SecKey? {
        // Strip PEM headers/footers and whitespace
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

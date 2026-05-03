import CryptoKit
import Foundation
import os
import Security
import SwiftASN1
import X509

actor MCPTLSManager {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPTLSManager")
    private static let keychainLabel = "com.tablepro.mcp-tls"
    private static let keyApplicationTag = Data("com.tablepro.mcp-tls.key".utf8)
    private static let certificateValiditySeconds: TimeInterval = 365 * 24 * 60 * 60
    private static let renewalThresholdSeconds: TimeInterval = 30 * 24 * 60 * 60

    private(set) var fingerprint: String?
    private(set) var pemCertificate: String?

    func loadOrGenerate() throws -> SecIdentity {
        if let existing = try? loadExistingIdentity() {
            return existing
        }

        return try generateAndStore()
    }

    func regenerate() throws -> SecIdentity {
        deleteIdentity()
        return try generateAndStore()
    }

    func deleteIdentity() {
        deleteKeychainKey()
        deleteKeychainCertificate()
        fingerprint = nil
        pemCertificate = nil
        Self.logger.info("Deleted MCP TLS identity from Keychain")
    }

    private func loadExistingIdentity() throws -> SecIdentity {
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: Self.keychainLabel,
            kSecReturnRef as String: true
        ]

        var ref: CFTypeRef?
        let status = SecItemCopyMatching(identityQuery as CFDictionary, &ref)

        guard status == errSecSuccess, let ref else {
            throw MCPTLSError.identityNotFound
        }

        let identity = (ref as! SecIdentity) // swiftlint:disable:this force_cast

        var secCert: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(identity, &secCert)

        guard certStatus == errSecSuccess, let certificate = secCert else {
            throw MCPTLSError.identityNotFound
        }

        let derData = SecCertificateCopyData(certificate) as Data

        guard isCertificateValid(derData: derData) else {
            Self.logger.info("Existing MCP TLS certificate expired or near expiry, regenerating")
            throw MCPTLSError.certificateExpired
        }

        cacheMetadata(derData: derData)
        Self.logger.info("Loaded existing MCP TLS identity from Keychain")
        return identity
    }

    private func generateAndStore() throws -> SecIdentity {
        let privateKey = P256.Signing.PrivateKey()
        let derCertData = try generateCertificate(privateKey: privateKey)

        try importPrivateKey(privateKey)
        try importCertificate(derData: derCertData)

        let identity = try retrieveIdentity()
        cacheMetadata(derData: derCertData)

        Self.logger.info("Generated new MCP TLS certificate, fingerprint: \(self.fingerprint ?? "unknown", privacy: .public)")
        return identity
    }

    private func generateCertificate(privateKey: P256.Signing.PrivateKey) throws -> Data {
        let name = try DistinguishedName { CommonName("TablePro MCP Server") }

        let ipv4Loopback = ASN1OctetString(contentBytes: [127, 0, 0, 1][...])
        let ipv6Loopback = ASN1OctetString(contentBytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1][...])

        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            SubjectAlternativeNames([
                .dnsName("localhost"),
                .ipAddress(ipv4Loopback),
                .ipAddress(ipv6Loopback)
            ])
            try ExtendedKeyUsage([.serverAuth])
        }

        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(privateKey.publicKey),
            notValidBefore: now,
            notValidAfter: now.addingTimeInterval(Self.certificateValiditySeconds),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: .init(privateKey)
        )

        var serializer = DER.Serializer()
        try certificate.serialize(into: &serializer)
        return Data(serializer.serializedBytes)
    }

    private func importPrivateKey(_ privateKey: P256.Signing.PrivateKey) throws {
        deleteKeychainKey()

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrLabel as String: Self.keychainLabel,
            kSecAttrApplicationTag as String: Self.keyApplicationTag,
            kSecValueData as String: privateKey.x963Representation
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        guard status == errSecSuccess else {
            Self.logger.error("Failed to import private key to Keychain: \(status)")
            throw MCPTLSError.keychainImportFailed(status)
        }
    }

    private func importCertificate(derData: Data) throws {
        deleteKeychainCertificate()

        guard let secCert = SecCertificateCreateWithData(nil, derData as CFData) else {
            throw MCPTLSError.certificateGenerationFailed
        }

        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: secCert,
            kSecAttrLabel as String: Self.keychainLabel
        ]

        let status = SecItemAdd(certQuery as CFDictionary, nil)

        guard status == errSecSuccess else {
            Self.logger.error("Failed to import certificate to Keychain: \(status)")
            throw MCPTLSError.keychainImportFailed(status)
        }
    }

    private func retrieveIdentity() throws -> SecIdentity {
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: Self.keychainLabel,
            kSecReturnRef as String: true
        ]

        var ref: CFTypeRef?
        let status = SecItemCopyMatching(identityQuery as CFDictionary, &ref)

        guard status == errSecSuccess, let ref else {
            Self.logger.error("Failed to retrieve identity after import: \(status)")
            throw MCPTLSError.identityNotFound
        }

        return (ref as! SecIdentity) // swiftlint:disable:this force_cast
    }

    private func deleteKeychainKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: Self.keychainLabel,
            kSecAttrApplicationTag as String: Self.keyApplicationTag
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Self.logger.warning("Failed to delete existing private key: \(status)")
        }
    }

    private func deleteKeychainCertificate() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: Self.keychainLabel
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Self.logger.warning("Failed to delete existing certificate: \(status)")
        }
    }

    private func isCertificateValid(derData: Data) -> Bool {
        do {
            let certificate = try Certificate(derEncoded: Array(derData))
            let threshold = Date().addingTimeInterval(Self.renewalThresholdSeconds)
            return certificate.notValidAfter > threshold
        } catch {
            Self.logger.warning("Failed to parse certificate for expiry check: \(error.localizedDescription)")
            return false
        }
    }

    private func cacheMetadata(derData: Data) {
        fingerprint = computeFingerprint(derData: derData)
        pemCertificate = encodePem(derData: derData)
    }

    private func computeFingerprint(derData: Data) -> String {
        SHA256.hash(data: derData)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    private func encodePem(derData: Data) -> String {
        let base64 = derData.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----"
    }
}

private enum MCPTLSError: LocalizedError {
    case keyGenerationFailed
    case certificateGenerationFailed
    case keychainImportFailed(OSStatus)
    case identityNotFound
    case certificateExpired

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return String(localized: "Failed to generate TLS private key")
        case .certificateGenerationFailed:
            return String(localized: "Failed to generate TLS certificate")
        case .keychainImportFailed(let status):
            return String(format: String(localized: "Failed to import TLS identity into Keychain (error %d)"), status)
        case .identityNotFound:
            return String(localized: "TLS identity not found in Keychain")
        case .certificateExpired:
            return String(localized: "TLS certificate expired or near expiry")
        }
    }
}

import CryptoKit
import Foundation
import Security

public enum TLSClientIdentityError: Error, Sendable, Equatable {
    case certificateFileUnreadable
    case keyFileUnreadable
    case certificateUnreadable
    case keyUnreadable
    case keyEncrypted
    case keyDoesNotMatchCertificate
}

public enum TLSClientIdentity {
    public static func credential(certificateFile: URL, privateKeyFile: URL) throws -> URLCredential {
        guard let certificate = try? Data(contentsOf: certificateFile) else {
            throw TLSClientIdentityError.certificateFileUnreadable
        }
        guard let privateKey = try? Data(contentsOf: privateKeyFile) else {
            throw TLSClientIdentityError.keyFileUnreadable
        }
        return try credential(certificate: certificate, privateKey: privateKey)
    }

    public static func credential(certificate: Data, privateKey: Data) throws -> URLCredential {
        let certificates = importedCertificates(from: certificate)
        guard !certificates.isEmpty else { throw TLSClientIdentityError.certificateUnreadable }
        let key = try importedPrivateKey(from: privateKey)
        for (index, leaf) in certificates.enumerated() {
            guard let identity = SecIdentityCreate(nil, leaf, key) else { continue }
            var intermediates = certificates
            intermediates.remove(at: index)
            return URLCredential(
                identity: identity,
                certificates: intermediates.isEmpty ? nil : intermediates,
                persistence: .forSession
            )
        }
        throw TLSClientIdentityError.keyDoesNotMatchCertificate
    }

    private static func importedCertificates(from data: Data) -> [SecCertificate] {
        importedItems(from: data, expecting: .itemTypeUnknown).compactMap { item in
            guard CFGetTypeID(item) == SecCertificateGetTypeID() else { return nil }
            return unsafeDowncast(item, to: SecCertificate.self)
        }
    }

    private static func importedPrivateKey(from data: Data) throws -> SecKey {
        let keyText = String(data: data, encoding: .utf8).flatMap(privateKeyBlock(in:))
        if let keyText, isEncrypted(keyText) {
            throw TLSClientIdentityError.keyEncrypted
        }
        if let x963 = ellipticCurveX963(pem: keyText, der: data), let key = ellipticCurveKey(x963: x963) {
            return key
        }
        let source = keyText.map { Data($0.utf8) } ?? data
        let imported = importedItems(from: source, expecting: .itemTypePrivateKey)
        guard let key = imported.first(where: { CFGetTypeID($0) == SecKeyGetTypeID() }) else {
            throw TLSClientIdentityError.keyUnreadable
        }
        return unsafeDowncast(key, to: SecKey.self)
    }

    private static func importedItems(from data: Data, expecting type: SecExternalItemType) -> [AnyObject] {
        var format = SecExternalFormat.formatUnknown
        var itemType = type
        var items: CFArray?
        guard SecItemImport(data as CFData, nil, &format, &itemType, [], nil, nil, &items) == errSecSuccess,
              let items else {
            return []
        }
        return items as [AnyObject]
    }

    private static func privateKeyBlock(in text: String) -> String? {
        guard let begin = text.range(of: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, options: .regularExpression),
              let end = text.range(
                  of: #"-----END [A-Z ]*PRIVATE KEY-----"#,
                  options: .regularExpression,
                  range: begin.upperBound..<text.endIndex
              ) else {
            return nil
        }
        return String(text[begin.lowerBound..<end.upperBound])
    }

    private static func isEncrypted(_ keyText: String) -> Bool {
        keyText.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----") || keyText.contains("Proc-Type: 4,ENCRYPTED")
    }

    private static func ellipticCurveX963(pem: String?, der: Data) -> Data? {
        if let pem {
            return (try? P256.Signing.PrivateKey(pemRepresentation: pem))?.x963Representation
                ?? (try? P384.Signing.PrivateKey(pemRepresentation: pem))?.x963Representation
                ?? (try? P521.Signing.PrivateKey(pemRepresentation: pem))?.x963Representation
        }
        return (try? P256.Signing.PrivateKey(derRepresentation: der))?.x963Representation
            ?? (try? P384.Signing.PrivateKey(derRepresentation: der))?.x963Representation
            ?? (try? P521.Signing.PrivateKey(derRepresentation: der))?.x963Representation
    }

    private static func ellipticCurveKey(x963: Data) -> SecKey? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        return SecKeyCreateWithData(x963 as CFData, attributes as CFDictionary, nil)
    }
}

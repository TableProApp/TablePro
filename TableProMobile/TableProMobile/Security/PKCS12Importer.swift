import CryptoKit
import Foundation
import Security

nonisolated struct ClientCertificateMaterial: Equatable, Sendable {
    let certificateChainPEM: String
    let privateKeyPEM: String
    let commonName: String?
}

nonisolated enum PKCS12ImportError: Error, LocalizedError, Equatable {
    case passwordRequired
    case importFailed(OSStatus)
    case noIdentityInFile
    case unsupportedPrivateKey

    var errorDescription: String? {
        switch self {
        case .passwordRequired:
            return String(localized: "This certificate file needs a password. Certificate files exported without one cannot be read on iOS.")
        case .importFailed:
            return String(localized: "The certificate file could not be read. Check the password and that the file is a PKCS#12 certificate.")
        case .noIdentityInFile:
            return String(localized: "This file has no private key. Export the certificate together with its key.")
        case .unsupportedPrivateKey:
            return String(localized: "This certificate uses a private key type TablePro cannot read.")
        }
    }
}

nonisolated enum PKCS12Importer {
    static func material(from data: Data, password: String) throws -> ClientCertificateMaterial {
        guard !password.isEmpty else { throw PKCS12ImportError.passwordRequired }

        var rawItems: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &rawItems)
        guard status == errSecSuccess else { throw PKCS12ImportError.importFailed(status) }

        guard let items = rawItems as? [[String: Any]],
              let first = items.first,
              let identityValue = first[kSecImportItemIdentity as String] else {
            throw PKCS12ImportError.noIdentityInFile
        }

        let identityObject = identityValue as AnyObject
        guard CFGetTypeID(identityObject) == SecIdentityGetTypeID() else {
            throw PKCS12ImportError.noIdentityInFile
        }
        let identity = unsafeDowncast(identityObject, to: SecIdentity.self)

        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let leaf = certificate else {
            throw PKCS12ImportError.noIdentityInFile
        }

        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let privateKey = key else {
            throw PKCS12ImportError.noIdentityInFile
        }

        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? [leaf]
        return ClientCertificateMaterial(
            certificateChainPEM: chainPEM(leaf: leaf, chain: chain),
            privateKeyPEM: try privateKeyPEM(for: privateKey),
            commonName: SecCertificateCopySubjectSummary(leaf) as String?
        )
    }

    static func chainPEM(leaf: SecCertificate, chain: [SecCertificate]) -> String {
        let leafData = SecCertificateCopyData(leaf) as Data
        let ordered = [leafData] + chain
            .map { SecCertificateCopyData($0) as Data }
            .filter { $0 != leafData }
        return ordered.map { PEMDocument.encode($0, as: .certificate) }.joined()
    }

    static func privateKeyPEM(for key: SecKey) throws -> String {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String else {
            throw PKCS12ImportError.unsupportedPrivateKey
        }

        var exportError: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(key, &exportError) as Data? else {
            exportError?.release()
            throw PKCS12ImportError.unsupportedPrivateKey
        }

        if keyType == (kSecAttrKeyTypeRSA as String) {
            return PEMDocument.encode(representation, as: .rsaPrivateKey)
        }

        guard keyType == (kSecAttrKeyTypeECSECPrimeRandom as String),
              let bits = attributes[kSecAttrKeySizeInBits as String] as? Int else {
            throw PKCS12ImportError.unsupportedPrivateKey
        }

        switch bits {
        case 256:
            return try P256.Signing.PrivateKey(x963Representation: representation).pemRepresentation + "\n"
        case 384:
            return try P384.Signing.PrivateKey(x963Representation: representation).pemRepresentation + "\n"
        case 521:
            return try P521.Signing.PrivateKey(x963Representation: representation).pemRepresentation + "\n"
        default:
            throw PKCS12ImportError.unsupportedPrivateKey
        }
    }
}

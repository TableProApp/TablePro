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
        let blocks = PEMBlock.all(in: data).filter { $0.label == "CERTIFICATE" }
        let ders = blocks.isEmpty ? [data] : blocks.compactMap(\.der)
        return ders.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    private static func importedPrivateKey(from data: Data) throws -> SecKey {
        let block = PEMBlock.all(in: data).first { $0.label.hasSuffix("PRIVATE KEY") }
        let der: Data
        if let block {
            guard !block.isEncrypted else { throw TLSClientIdentityError.keyEncrypted }
            guard let blockDER = block.der else { throw TLSClientIdentityError.keyUnreadable }
            der = blockDER
        } else {
            der = data
        }
        if let x963 = ellipticCurveX963(der: der), let key = privateKey(der: x963, type: kSecAttrKeyTypeECSECPrimeRandom) {
            return key
        }
        guard let pkcs1 = rsaPKCS1(der: der, label: block?.label),
              let key = privateKey(der: pkcs1, type: kSecAttrKeyTypeRSA) else {
            throw TLSClientIdentityError.keyUnreadable
        }
        return key
    }

    private static func ellipticCurveX963(der: Data) -> Data? {
        (try? P256.Signing.PrivateKey(derRepresentation: der))?.x963Representation
            ?? (try? P384.Signing.PrivateKey(derRepresentation: der))?.x963Representation
            ?? (try? P521.Signing.PrivateKey(derRepresentation: der))?.x963Representation
    }

    private static func rsaPKCS1(der: Data, label: String?) -> Data? {
        switch label {
        case nil:
            return pkcs1(fromPKCS8: der) ?? (isPKCS1(der) ? der : nil)
        case "RSA PRIVATE KEY":
            return isPKCS1(der) ? der : nil
        case "PRIVATE KEY":
            return pkcs1(fromPKCS8: der)
        default:
            return nil
        }
    }

    private static let rsaEncryptionOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    private static func pkcs1(fromPKCS8 der: Data) -> Data? {
        var outer = DERReader(Array(der)[...])
        guard let privateKeyInfo = outer.read(DERReader.sequence), outer.isAtEnd else { return nil }
        var fields = DERReader(privateKeyInfo)
        guard fields.read(DERReader.integer) != nil,
              let algorithm = fields.read(DERReader.sequence) else { return nil }
        var algorithmFields = DERReader(algorithm)
        guard let oid = algorithmFields.read(DERReader.objectIdentifier),
              oid.elementsEqual(rsaEncryptionOID),
              let wrapped = fields.read(DERReader.octetString) else { return nil }
        let pkcs1 = Data(wrapped)
        return isPKCS1(pkcs1) ? pkcs1 : nil
    }

    private static func isPKCS1(_ der: Data) -> Bool {
        var outer = DERReader(Array(der)[...])
        guard let rsaPrivateKey = outer.read(DERReader.sequence), outer.isAtEnd else { return false }
        var fields = DERReader(rsaPrivateKey)
        // RSAPrivateKey opens with version, n, e, d, p, q, dp, dq, qinv (RFC 8017, A.1.2).
        for _ in 0..<9 {
            guard fields.read(DERReader.integer) != nil else { return false }
        }
        return true
    }

    private static func privateKey(der: Data, type: CFString) -> SecKey? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: type,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}

private struct PEMBlock {
    let label: String
    let headers: [String]
    let der: Data?

    var isEncrypted: Bool {
        label == "ENCRYPTED PRIVATE KEY" || headers.contains { $0.hasPrefix("Proc-Type:") && $0.hasSuffix(",ENCRYPTED") }
    }

    private static let beginPrefix = "-----BEGIN "
    private static let boundarySuffix = "-----"

    static func all(in data: Data) -> [PEMBlock] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var blocks: [PEMBlock] = []
        var open: (label: String, headers: [String], body: String)?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(beginPrefix), line.hasSuffix(boundarySuffix),
               line.count >= beginPrefix.count + boundarySuffix.count {
                open = (String(line.dropFirst(beginPrefix.count).dropLast(boundarySuffix.count)), [], "")
            } else if let current = open, line == "-----END \(current.label)-----" {
                blocks.append(PEMBlock(label: current.label, headers: current.headers, der: Data(base64Encoded: current.body)))
                open = nil
            } else if open != nil {
                // RFC 1421 headers such as Proc-Type and DEK-Info; base64 never holds a colon.
                if line.contains(":") {
                    open?.headers.append(line)
                } else {
                    open?.body += line
                }
            }
        }
        return blocks
    }
}

private struct DERReader {
    static let integer: UInt8 = 0x02
    static let octetString: UInt8 = 0x04
    static let objectIdentifier: UInt8 = 0x06
    static let sequence: UInt8 = 0x30

    private let bytes: ArraySlice<UInt8>
    private var offset: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        offset = bytes.startIndex
    }

    var isAtEnd: Bool {
        offset == bytes.endIndex
    }

    mutating func read(_ tag: UInt8) -> ArraySlice<UInt8>? {
        guard bytes.endIndex - offset >= 2, bytes[offset] == tag else { return nil }
        var cursor = offset + 1
        let first = bytes[cursor]
        cursor += 1
        var length = Int(first)
        if first & 0x80 != 0 {
            let octetCount = Int(first & 0x7F)
            guard (1...4).contains(octetCount), octetCount <= bytes.endIndex - cursor else { return nil }
            length = bytes[cursor..<(cursor + octetCount)].reduce(0) { $0 << 8 | Int($1) }
            cursor += octetCount
        }
        guard length <= bytes.endIndex - cursor else { return nil }
        offset = cursor + length
        return bytes[cursor..<offset]
    }
}

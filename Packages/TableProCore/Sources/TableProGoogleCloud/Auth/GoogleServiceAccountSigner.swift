import Foundation
import Security

internal struct GoogleServiceAccountSigner {
    private static let maximumPEMLength = 65_536
    private static let rsaEncryptionOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    private static let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256

    private let key: SecKey

    init(privateKeyPEM: String) throws {
        let der = try Self.der(fromPEM: privateKeyPEM)
        let pkcs1 = try Self.pkcs1(fromDER: der)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, nil),
              SecKeyIsAlgorithmSupported(key, .sign, Self.algorithm)
        else {
            throw GoogleAuthError.malformedPrivateKey
        }
        self.key = key
    }

    func sign(_ message: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, Self.algorithm, message as CFData, &error) else {
            error?.release()
            throw GoogleAuthError.signingFailed
        }
        return signature as Data
    }

    static func der(fromPEM pem: String) throws -> [UInt8] {
        guard pem.utf8.count <= maximumPEMLength else { throw GoogleAuthError.malformedPrivateKey }
        let normalized = pem
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let body = try armouredBody(lines)
        guard !body.isEmpty, let data = Data(base64Encoded: body.joined()), !data.isEmpty else {
            throw GoogleAuthError.malformedPrivateKey
        }
        return Array(data)
    }

    static func pkcs1(fromDER der: [UInt8]) throws -> ArraySlice<UInt8> {
        var outer = GoogleDERReader(der[...])
        let sequence = try outer.read(expecting: GoogleDERReader.Tag.sequence)
        guard outer.isAtEnd else { throw GoogleAuthError.malformedPrivateKey }
        var fields = GoogleDERReader(sequence.content)
        _ = try fields.read(expecting: GoogleDERReader.Tag.integer)
        let second = try fields.readElement()
        switch second.tag {
        case GoogleDERReader.Tag.integer:
            return der[...]
        case GoogleDERReader.Tag.sequence:
            try requireRSAEncryption(second.content)
            let wrapped = try fields.read(expecting: GoogleDERReader.Tag.octetString)
            try requirePKCS1Structure(wrapped.content)
            return wrapped.content
        default:
            throw GoogleAuthError.malformedPrivateKey
        }
    }

    private static func armouredBody(_ lines: [String]) throws -> [String] {
        guard let beginIndex = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN") }) else {
            return lines.filter { !$0.hasPrefix("-----") }
        }
        guard !lines[beginIndex].contains("ENCRYPTED"),
              let endIndex = lines[beginIndex...].firstIndex(where: { $0.hasPrefix("-----END") })
        else {
            throw GoogleAuthError.malformedPrivateKey
        }
        return Array(lines[(beginIndex + 1)..<endIndex])
    }

    private static func requireRSAEncryption(_ algorithmIdentifier: ArraySlice<UInt8>) throws {
        var reader = GoogleDERReader(algorithmIdentifier)
        let oid = try reader.read(expecting: GoogleDERReader.Tag.objectIdentifier)
        guard oid.content.elementsEqual(rsaEncryptionOID) else { throw GoogleAuthError.malformedPrivateKey }
    }

    private static func requirePKCS1Structure(_ bytes: ArraySlice<UInt8>) throws {
        var outer = GoogleDERReader(bytes)
        let sequence = try outer.read(expecting: GoogleDERReader.Tag.sequence)
        guard outer.isAtEnd else { throw GoogleAuthError.malformedPrivateKey }
        var fields = GoogleDERReader(sequence.content)
        _ = try fields.read(expecting: GoogleDERReader.Tag.integer)
        _ = try fields.read(expecting: GoogleDERReader.Tag.integer)
    }
}

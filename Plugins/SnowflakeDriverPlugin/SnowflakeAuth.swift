//
//  SnowflakeAuth.swift
//  SnowflakeDriverPlugin
//
//  Account identifier parsing, key-pair JWT generation, and
//  ~/.snowflake/connections.toml parsing.
//

import CryptoKit
import Foundation
import os
import Security

enum SnowflakeAccount {
    static func host(forAccount account: String) -> String {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix(".snowflakecomputing.com") {
            return trimmed
        }
        if trimmed.contains("://") {
            return URL(string: trimmed)?.host ?? trimmed
        }
        return "\(trimmed).snowflakecomputing.com"
    }

    /// The account name used as the JWT issuer/subject prefix. Snowflake expects the
    /// account locator without any region/cloud segment, uppercased.
    static func issuerAccountName(forAccount account: String) -> String {
        var name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".snowflakecomputing.com") {
            name = String(name.dropLast(".snowflakecomputing.com".count))
        }
        if let dotIndex = name.firstIndex(of: ".") {
            name = String(name[..<dotIndex])
        }
        return name.uppercased()
    }
}

struct SnowflakeKeyPairAuth {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SnowflakeKeyPairAuth")

    let account: String
    let user: String
    let privateKeyPEM: String
    let passphrase: String?

    func makeJWT(lifetime: TimeInterval = 3_540) throws -> String {
        let privateKey = try loadPrivateKey()
        let qualifiedUser = "\(SnowflakeAccount.issuerAccountName(forAccount: account)).\(user.uppercased())"
        let fingerprint = try publicKeyFingerprint(for: privateKey)
        let issuer = "\(qualifiedUser).\(fingerprint)"

        let now = Date()
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + Int(lifetime)

        let headerJSON = #"{"alg":"RS256","typ":"JWT"}"#
        let claimsJSON = #"{"iss":"\#(issuer)","sub":"\#(qualifiedUser)","iat":\#(iat),"exp":\#(exp)}"#

        let signingInput = "\(base64URL(Data(headerJSON.utf8))).\(base64URL(Data(claimsJSON.utf8)))"
        let signature = try sign(Data(signingInput.utf8), with: privateKey)
        return "\(signingInput).\(base64URL(signature))"
    }

    private func loadPrivateKey() throws -> SecKey {
        guard let pemData = privateKeyPEM.data(using: .utf8) else {
            throw SnowflakeError.authFailed("Private key is not valid UTF-8")
        }

        var inputFormat = SecExternalFormat.formatUnknown
        var itemType = SecExternalItemType.itemTypeUnknown
        var importedItems: CFArray?

        var keyParams = SecItemImportExportKeyParameters()
        var passphraseRef: CFTypeRef?
        if let passphrase, !passphrase.isEmpty {
            let ref = passphrase as CFString
            passphraseRef = ref
            keyParams.passphrase = Unmanaged.passUnretained(ref)
        }
        _ = passphraseRef

        let status = SecItemImport(
            pemData as CFData,
            "p8" as CFString,
            &inputFormat,
            &itemType,
            SecItemImportExportFlags(rawValue: 0),
            &keyParams,
            nil,
            &importedItems
        )

        guard status == errSecSuccess,
              let items = importedItems as? [SecKey],
              let key = items.first
        else {
            throw SnowflakeError.authFailed(
                "Failed to load private key (OSStatus \(status)). Ensure the file is a valid RSA .p8 key and the passphrase is correct."
            )
        }
        return key
    }

    private func publicKeyFingerprint(for privateKey: SecKey) throws -> String {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SnowflakeError.authFailed("Could not derive public key from private key")
        }
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw SnowflakeError.authFailed("Could not export public key: \(message)")
        }
        let spki = Self.wrapPKCS1IntoSPKI(pkcs1)
        let digest = SHA256.hash(data: spki)
        return "SHA256:\(Data(digest).base64EncodedString())"
    }

    private func sign(_ data: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error
        ) as Data? else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw SnowflakeError.authFailed("Failed to sign JWT: \(message)")
        }
        return signature
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Wrap a PKCS#1 RSAPublicKey DER blob into a SubjectPublicKeyInfo DER blob,
    /// which is what Snowflake fingerprints with SHA-256.
    static func wrapPKCS1IntoSPKI(_ pkcs1: Data) -> Data {
        let rsaAlgorithmID: [UInt8] = [
            0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
            0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00
        ]
        var bitString: [UInt8] = [0x03]
        bitString += derLength(pkcs1.count + 1)
        bitString.append(0x00)
        bitString += [UInt8](pkcs1)

        var body = rsaAlgorithmID
        body += bitString

        var spki: [UInt8] = [0x30]
        spki += derLength(body.count)
        spki += body
        return Data(spki)
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [UInt8(0x80 | bytes.count)] + bytes
    }
}

enum SnowflakeConnectionsTOML {
    /// Look up the named connection in the Snowflake CLI's config files, checking
    /// ~/.snowflake/connections.toml first, then [connections.*] sections in
    /// ~/.snowflake/config.toml. Keys follow the CLI's snake_case naming
    /// (account, user, password, authenticator, private_key_file, role, ...).
    static func parameters(forConnection name: String) -> [String: String]? {
        for filename in ["connections.toml", "config.toml"] {
            let path = NSString(string: "~/.snowflake/\(filename)").expandingTildeInPath
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let section = parse(contents)[name] {
                return section
            }
        }
        return nil
    }

    static func parse(_ contents: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var currentSection: String?

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                var name = String(line.dropFirst().dropLast())
                if name.hasPrefix("connections.") {
                    name = String(name.dropFirst("connections.".count))
                }
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                currentSection = name
                if sections[name] == nil { sections[name] = [:] }
                continue
            }

            guard let section = currentSection,
                  let equalIndex = line.firstIndex(of: "=") else { continue }

            let key = line[..<equalIndex].trimmingCharacters(in: .whitespaces)
            let value = unquote(String(line[line.index(after: equalIndex)...]).trimmingCharacters(in: .whitespaces))
            sections[section]?[key] = value
        }
        return sections
    }

    private static func stripComment(_ line: String) -> String {
        var inDoubleQuotes = false
        var inSingleQuotes = false
        var result = ""
        for char in line {
            if char == "\"" && !inSingleQuotes { inDoubleQuotes.toggle() }
            if char == "'" && !inDoubleQuotes { inSingleQuotes.toggle() }
            if char == "#" && !inDoubleQuotes && !inSingleQuotes { break }
            result.append(char)
        }
        return result
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

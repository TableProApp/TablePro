import CommonCrypto
import CryptoKit
import Foundation

/// SCRAM's cryptography and the rules that decide whether a broker's half of the exchange
/// is acceptable. Split from the exchange itself because none of it needs a connection, so
/// all of it can be pinned against RFC 7677's published vectors.
enum KafkaScram {
    /// SASL PLAIN is authzid NUL authcid NUL password, and the leading empty authzid is
    /// required rather than optional. The password goes out exactly as typed: PLAIN defines
    /// no escaping, so altering it would send a different secret than the user has.
    static func plainAuthToken(username: String, password: String) -> Data {
        var token = Data()
        token.append(0)
        token.append(contentsOf: Array(username.utf8))
        token.append(0)
        token.append(contentsOf: Array(password.utf8))
        return token
    }

    enum ScramHash: Sendable {
        case sha256
        case sha512

        var digestLength: Int {
            switch self {
            case .sha256: return Int(CC_SHA256_DIGEST_LENGTH)
            case .sha512: return Int(CC_SHA512_DIGEST_LENGTH)
            }
        }

        var pbkdfAlgorithm: CCPseudoRandomAlgorithm {
            switch self {
            case .sha256: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
            case .sha512: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
            }
        }

        func hash(_ data: Data) -> Data {
            switch self {
            case .sha256: return Data(SHA256.hash(data: data))
            case .sha512: return Data(SHA512.hash(data: data))
            }
        }

        func hmac(key: Data, message: Data) -> Data {
            switch self {
            case .sha256:
                return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
            case .sha512:
                return Data(HMAC<SHA512>.authenticationCode(for: message, using: SymmetricKey(data: key)))
            }
        }
    }

    /// RFC 7677 sets the floor at 4096 and Kafka's own default is 4096. A broker naming a lower
    /// cost is choosing how cheaply an intercepted proof can be brute-forced offline.
    static func isAcceptableIterationCount(_ iterations: Int) -> Bool {
        iterations >= 4_096 && iterations <= 1_000_000
    }

    /// The server nonce must EXTEND the client's, not merely contain or equal it. A peer that
    /// does not is not answering this exchange, so accepting it would allow a replay.
    static func isValidServerNonce(_ serverNonce: String, clientNonce: String) -> Bool {
        serverNonce.hasPrefix(clientNonce) && serverNonce.count > clientNonce.count
    }

    static func clientProof(saltedPassword: Data, authMessage: Data, hash: ScramHash) -> Data {
        let clientKey = hash.hmac(key: saltedPassword, message: Data("Client Key".utf8))
        let storedKey = hash.hash(clientKey)
        let signature = hash.hmac(key: storedKey, message: authMessage)
        return Data(zip(clientKey, signature).map { $0 ^ $1 })
    }

    static func serverSignature(saltedPassword: Data, authMessage: Data, hash: ScramHash) -> Data {
        let serverKey = hash.hmac(key: saltedPassword, message: Data("Server Key".utf8))
        return hash.hmac(key: serverKey, message: authMessage)
    }

    static func saltedPassword(password: String, salt: Data, iterations: Int, hash: ScramHash) throws -> Data {
        var derived = [UInt8](repeating: 0, count: hash.digestLength)
        let passwordBytes = Array(password.utf8)
        let saltBytes = [UInt8](salt)
        let status = saltBytes.withUnsafeBufferPointer { saltBuffer -> Int32 in
            derived.withUnsafeMutableBufferPointer { derivedBuffer -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, passwordBytes.count,
                    saltBuffer.baseAddress, saltBuffer.count,
                    hash.pbkdfAlgorithm,
                    UInt32(iterations),
                    derivedBuffer.baseAddress, derivedBuffer.count
                )
            }
        }
        guard status == kCCSuccess else {
            throw KafkaError.authenticationFailed(String(localized: "could not derive the SCRAM key"))
        }
        return Data(derived)
    }

    static func makeClientNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0 ... 255) }
        return Data(bytes).base64EncodedString().filter { $0 != "," && $0 != "=" }
    }

    /// RFC 5802's `saslname` escaping. It applies to the USERNAME in the `n=` attribute, whose
    /// commas and equals signs would otherwise break SCRAM's own framing. It must never be
    /// applied to the password: PBKDF2 takes the password as typed, and escaping it first
    /// derives a different key than the broker computed, so every password containing `,` or
    /// `=` would fail to authenticate.
    static func escapedUsername(_ value: String) -> String {
        value.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
    }

    static func parseAttributes(_ message: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for field in message.split(separator: ",") {
            guard let separator = field.firstIndex(of: "=") else { continue }
            let key = String(field[field.startIndex ..< separator])
            let value = String(field[field.index(after: separator)...])
            attributes[key] = value
        }
        return attributes
    }

    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}

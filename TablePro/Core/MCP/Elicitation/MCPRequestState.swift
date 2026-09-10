import CryptoKit
import Foundation

public enum MCPRequestStateError: Error, Equatable, Sendable {
    case malformed
    case signatureMismatch
    case expired
    case principalMismatch
    case requestMismatch

    public var detail: String {
        switch self {
        case .malformed:
            return "requestState is malformed"
        case .signatureMismatch:
            return "requestState failed integrity verification"
        case .expired:
            return "requestState has expired"
        case .principalMismatch:
            return "requestState was issued to a different principal"
        case .requestMismatch:
            return "requestState was issued for a different request"
        }
    }
}

public enum MCPRequestState {
    public static let defaultLifetime: TimeInterval = 300

    public static func seal(
        _ payload: JsonValue,
        principal: MCPPrincipal,
        method: String,
        paramsDigest: String,
        expiresAt: Date
    ) throws -> String {
        let envelope = Envelope(
            version: 1,
            principal: principal.tokenFingerprint,
            tokenId: principal.tokenId?.uuidString,
            method: method,
            digest: paramsDigest,
            expiresAt: Int(expiresAt.timeIntervalSince1970.rounded()),
            nonce: randomNonce(),
            state: payload
        )
        let body = try canonicalEncoder.encode(envelope)
        let signature = HMAC<SHA256>.authenticationCode(for: body, using: signingKey)
        return base64UrlEncode(body) + "." + base64UrlEncode(Data(signature))
    }

    public static func open(
        _ token: String,
        principal: MCPPrincipal,
        method: String,
        paramsDigest: String,
        now: Date
    ) throws -> JsonValue {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let body = base64UrlDecode(String(parts[0])),
              let signature = base64UrlDecode(String(parts[1]))
        else {
            throw MCPRequestStateError.malformed
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: body, using: signingKey) else {
            throw MCPRequestStateError.signatureMismatch
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body), envelope.version == 1 else {
            throw MCPRequestStateError.malformed
        }
        guard envelope.principal == principal.tokenFingerprint,
              envelope.tokenId == principal.tokenId?.uuidString
        else {
            throw MCPRequestStateError.principalMismatch
        }
        guard Double(envelope.expiresAt) > now.timeIntervalSince1970 else {
            throw MCPRequestStateError.expired
        }
        guard envelope.method == method, envelope.digest == paramsDigest else {
            throw MCPRequestStateError.requestMismatch
        }
        return envelope.state
    }

    public static func digest(ofParams params: JsonValue?) -> String {
        let salient = salientParameters(params)
        guard let data = try? canonicalEncoder.encode(salient) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func salientParameters(_ params: JsonValue?) -> JsonValue {
        guard case .object(let fields)? = params else { return .object([:]) }
        var copy = fields
        for key in ["_meta", "inputResponses", "requestState"] {
            copy.removeValue(forKey: key)
        }
        return .object(copy)
    }
}

private extension MCPRequestState {
    struct Envelope: Codable {
        let version: Int
        let principal: String
        let tokenId: String?
        let method: String
        let digest: String
        let expiresAt: Int
        let nonce: String
        let state: JsonValue
    }

    static let signingKey = SymmetricKey(size: .bits256)

    static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return UUID().uuidString
        }
        return base64UrlEncode(Data(bytes))
    }

    static func base64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64UrlDecode(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }
}

//
//  EntitlementVerifier.swift
//  TablePro
//

import CryptoKit
import Foundation

internal struct EntitlementVerifier: Sendable {
    enum Failure: Error, Equatable {
        case malformed
        case algorithm
        case type
        case unknownKey
        case signature
        case audience
        case machine
        case notYetValid
        case expired
    }

    static let algorithm = "EdDSA"
    static let tokenType = "tablepro-entitlement+jwt"
    static let audience = "tablepro-app"
    static let notBeforeLeeway: TimeInterval = 5 * 60

    let keys: [String: Curve25519.Signing.PublicKey]

    init(keys: [String: Curve25519.Signing.PublicKey]) {
        self.keys = keys
    }

    init(publicKeys: [Curve25519.Signing.PublicKey]) {
        self.keys = Dictionary(publicKeys.map { (Self.keyID(of: $0), $0) }) { first, _ in first }
    }

    // RFC 7638 thumbprint of the OKP JWK, which the server puts in kid.
    static func keyID(of key: Curve25519.Signing.PublicKey) -> String {
        let jwk = #"{"crv":"Ed25519","kty":"OKP","x":"\#(Base64URL.encode(key.rawRepresentation))"}"#
        return Base64URL.encode(Data(SHA256.hash(data: Data(jwk.utf8))))
    }

    func verify(_ token: String, machineID: String, now: Date) throws(Failure) -> Entitlement {
        let entitlement = try verifySignature(token, machineID: machineID)
        guard entitlement.notBefore <= now.addingTimeInterval(Self.notBeforeLeeway) else { throw .notYetValid }
        guard now < entitlement.expiresAt else { throw .expired }
        return entitlement
    }

    // Every check but the clock, so an expired token on disk can still say what it carried.
    func verifySignature(_ token: String, machineID: String) throws(Failure) -> Entitlement {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Base64URL.decode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else { throw .malformed }

        guard header["alg"] as? String == Self.algorithm else { throw .algorithm }
        guard header["typ"] as? String == Self.tokenType else { throw .type }
        guard header["crit"] == nil else { throw .malformed }
        guard let keyID = header["kid"] as? String, let key = keys[keyID] else { throw .unknownKey }

        guard let signature = Base64URL.decode(parts[2]),
              key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8))
        else { throw .signature }

        guard let payload = Base64URL.decode(parts[1]),
              let claims = try? JSONDecoder().decode(Entitlement.Claims.self, from: payload)
        else { throw .malformed }
        guard claims.aud == Self.audience else { throw .audience }
        guard claims.mid == machineID else { throw .machine }
        return try Entitlement(token: token, claims: claims)
    }
}

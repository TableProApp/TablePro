//
//  EntitlementVerifierTests.swift
//  TableProTests
//

import CryptoKit
import Foundation
@testable import TablePro
import Testing

// entitlement_vectors.json is tablepro-cloud's internal/licensing/adapter/jws/testdata, signed by its signer.
struct EntitlementVerifierTests {
    private struct Vectors: Decodable {
        struct Key: Decodable {
            let kid: String
            let x: String
        }

        struct Case: Decodable {
            let name: String
            let token: String
            let check: String?
            let claims: Claims?
        }

        struct Claims: Decodable {
            struct License: Decodable {
                let id: String
                let renewsAt: String?
                let endsAt: String?

                enum CodingKeys: String, CodingKey {
                    case id
                    case renewsAt = "renews_at"
                    case endsAt = "ends_at"
                }
            }

            let sub: String
            let dev: String
            let features: [String]
            let exp: Int64
            let offline: Bool
            let licenses: [License]
        }

        let key: Key
        let machineID: String
        let now: Int64
        let valid: [Case]
        let invalid: [Case]

        enum CodingKeys: String, CodingKey {
            case key, now, valid, invalid
            case machineID = "machine_id"
        }
    }

    private static func vectors(file: StaticString = #filePath) throws -> Vectors {
        let url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("entitlement_vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private static func verifier(_ vectors: Vectors) throws -> EntitlementVerifier {
        let raw = try #require(Base64URL.decode(vectors.key.x))
        return EntitlementVerifier(publicKeys: [try Curve25519.Signing.PublicKey(rawRepresentation: raw)])
    }

    private static let failures: [String: EntitlementVerifier.Failure] = [
        "alg": .algorithm, "typ": .type, "kid": .unknownKey, "signature": .signature,
        "aud": .audience, "mid": .machine, "nbf": .notYetValid, "exp": .expired
    ]

    @Test("The kid is the RFC 7638 thumbprint the server writes")
    func keyIDMatchesTheServer() throws {
        let vectors = try Self.vectors()
        let raw = try #require(Base64URL.decode(vectors.key.x))
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        #expect(EntitlementVerifier.keyID(of: key) == vectors.key.kid)
    }

    @Test("Every valid vector verifies and decodes to its claims")
    func validVectorsVerify() throws {
        let vectors = try Self.vectors()
        let verifier = try Self.verifier(vectors)
        let now = Date(timeIntervalSince1970: TimeInterval(vectors.now))
        for vector in vectors.valid {
            let entitlement = try verifier.verify(vector.token, machineID: vectors.machineID, now: now)
            let claims = try #require(vector.claims)
            #expect(entitlement.accountID == claims.sub, "\(vector.name)")
            #expect(entitlement.deviceID == claims.dev, "\(vector.name)")
            #expect(entitlement.features == Set(claims.features), "\(vector.name)")
            #expect(entitlement.expiresAt == Date(timeIntervalSince1970: TimeInterval(claims.exp)), "\(vector.name)")
            #expect(entitlement.isOffline == claims.offline, "\(vector.name)")
            #expect(entitlement.licenses.map { $0.id } == claims.licenses.map { $0.id }, "\(vector.name)")
            for (license, claim) in zip(entitlement.licenses, claims.licenses) {
                #expect(license.renewsAt == claim.renewsAt.flatMap { try? Date($0, strategy: .iso8601) }, "\(vector.name)")
                #expect(license.endsAt == claim.endsAt.flatMap { try? Date($0, strategy: .iso8601) }, "\(vector.name)")
            }
        }
    }

    @Test("The vectors include a subscription that renews, so renews_at is read from a real token")
    func vectorsCarryARenewal() throws {
        let vectors = try Self.vectors()
        let verifier = try Self.verifier(vectors)
        let now = Date(timeIntervalSince1970: TimeInterval(vectors.now))
        let renewals = try vectors.valid.flatMap { vector in
            try verifier.verify(vector.token, machineID: vectors.machineID, now: now).licenses.compactMap(\.renewsAt)
        }
        #expect(renewals == [try Date("2026-11-14T10:00:00Z", strategy: .iso8601)])
    }

    @Test("Every invalid vector fails the check it names")
    func invalidVectorsFailTheirCheck() throws {
        let vectors = try Self.vectors()
        let verifier = try Self.verifier(vectors)
        let now = Date(timeIntervalSince1970: TimeInterval(vectors.now))
        for vector in vectors.invalid {
            let expected = try #require(Self.failures[vector.check ?? ""], "\(vector.name)")
            #expect(throws: expected, "\(vector.name)") {
                try verifier.verify(vector.token, machineID: vectors.machineID, now: now)
            }
        }
    }

    @Test("A token past its exp still reads, so the app can say what lapsed")
    func expiredTokenStillReads() throws {
        let vectors = try Self.vectors()
        let verifier = try Self.verifier(vectors)
        let expired = try #require(vectors.invalid.first { $0.check == "exp" })
        let entitlement = try verifier.verifySignature(expired.token, machineID: vectors.machineID)
        #expect(!entitlement.isValid(at: Date(timeIntervalSince1970: TimeInterval(vectors.now))))
    }

    @Test("A token that is not three base64url parts is malformed")
    func malformedTokens() throws {
        let verifier = try Self.verifier(try Self.vectors())
        for token in ["", "a.b", "a.b.c.d", "e30=.e30.c2ln", "!!.e30.c2ln"] {
            #expect(throws: EntitlementVerifier.Failure.malformed, "\(token)") {
                try verifier.verifySignature(token, machineID: "")
            }
        }
    }

    @Test("Base64url decoding refuses padding and the standard alphabet")
    func base64URLIsStrict() {
        #expect(Base64URL.decode("YQ") == Data("a".utf8))
        #expect(Base64URL.decode("YQ==") == nil)
        #expect(Base64URL.decode("+/8") == nil)
        #expect(Base64URL.decode("-_8") == Data([0xFB, 0xFF]))
        #expect(Base64URL.decode("A") == nil)
        #expect(Base64URL.encode(Data([0xFB, 0xFF])) == "-_8")
    }
}

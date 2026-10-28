//
//  AccountConfigurationTests.swift
//  TableProTests
//

import CryptoKit
import Foundation
@testable import TablePro
import Testing

struct AccountConfigurationTests {
    @Test("Each embedded production key decodes, and its kid is the RFC 7638 thumbprint the server sends")
    func productionKeysMatchTheirKeyIDs() throws {
        for (kid, x) in AccountConfiguration.productionEntitlementKeys {
            let raw = try #require(Base64URL.decode(x), "kid \(kid) holds an x that is not base64url")
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
            #expect(EntitlementVerifier.keyID(of: key) == kid)
        }
        #expect(AccountConfiguration.production.entitlementKeys.count == AccountConfiguration.productionEntitlementKeys.count)
    }

    @Test("A release build verifies entitlements with at least one production key")
    func productionKeyIsEmbedded() {
        withKnownIssue("The owner supplies the production entitlement key before cutover") {
            #expect(!AccountConfiguration.productionEntitlementKeys.isEmpty)
        }
    }

    @Test("A Debug build's overrides point at another stack and add its key beside production's")
    func overridesAddTheLocalKey() throws {
        let local = Curve25519.Signing.PrivateKey().publicKey
        let configuration = AccountConfiguration.production.overridden(by: [
            "TABLEPRO_ACCOUNT_URL": "http://account.localhost:5284",
            "TABLEPRO_API_URL": "http://api.localhost:5284",
            "TABLEPRO_ENTITLEMENT_KEYS": Base64URL.encode(local.rawRepresentation)
        ])

        #expect(configuration.tokenEndpoint.absoluteString == "http://account.localhost:5284/oauth/token")
        #expect(configuration.apiServerURL.absoluteString == "http://api.localhost:5284/v2")
        #expect(configuration.entitlementKeys.map { $0.rawRepresentation }.contains(local.rawRepresentation))
    }
}

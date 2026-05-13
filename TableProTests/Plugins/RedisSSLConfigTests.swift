//
//  RedisSSLConfigTests.swift
//  TableProTests
//
//  Regression coverage for issue #1247: SSLMode.required must not verify peers.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Redis SSL handling")
struct RedisSSLConfigTests {
    @Test("disabled is not enabled and does not verify")
    func disabled() {
        let ssl = SSLConfiguration(mode: .disabled)
        #expect(ssl.isEnabled == false)
        #expect(ssl.verifiesCertificate == false)
        #expect(ssl.verifiesHostname == false)
    }

    @Test("preferred is enabled but does not verify")
    func preferred() {
        let ssl = SSLConfiguration(mode: .preferred)
        #expect(ssl.isEnabled)
        #expect(ssl.verifiesCertificate == false)
        #expect(ssl.verifiesHostname == false)
    }

    @Test("required is enabled and does not verify (skip verify)")
    func required() {
        let ssl = SSLConfiguration(mode: .required)
        #expect(ssl.isEnabled)
        #expect(ssl.verifiesCertificate == false)
        #expect(ssl.verifiesHostname == false)
    }

    @Test("verifyCa verifies the certificate but not the hostname")
    func verifyCa() {
        let ssl = SSLConfiguration(mode: .verifyCa)
        #expect(ssl.isEnabled)
        #expect(ssl.verifiesCertificate)
        #expect(ssl.verifiesHostname == false)
    }

    @Test("verifyIdentity verifies the certificate and the hostname")
    func verifyIdentity() {
        let ssl = SSLConfiguration(mode: .verifyIdentity)
        #expect(ssl.isEnabled)
        #expect(ssl.verifiesCertificate)
        #expect(ssl.verifiesHostname)
    }
}

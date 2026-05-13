//
//  RedisSSLConfigTests.swift
//  TableProTests
//
//  Regression coverage for issue #1247: SSLMode.required must not verify peers.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("RedisSSLConfig")
struct RedisSSLConfigTests {
    @Test("disabled is not enabled and does not verify")
    func disabled() {
        let cfg = RedisSSLConfig(SSLConfiguration(mode: .disabled))
        #expect(cfg.isEnabled == false)
        #expect(cfg.verifiesCertificate == false)
        #expect(cfg.verifiesHostname == false)
    }

    @Test("preferred is enabled but does not verify")
    func preferred() {
        let cfg = RedisSSLConfig(SSLConfiguration(mode: .preferred))
        #expect(cfg.isEnabled)
        #expect(cfg.verifiesCertificate == false)
        #expect(cfg.verifiesHostname == false)
    }

    @Test("required is enabled and does not verify (skip verify)")
    func required() {
        let cfg = RedisSSLConfig(SSLConfiguration(mode: .required))
        #expect(cfg.isEnabled)
        #expect(cfg.verifiesCertificate == false)
        #expect(cfg.verifiesHostname == false)
    }

    @Test("verifyCa verifies the certificate but not the hostname")
    func verifyCa() {
        let cfg = RedisSSLConfig(SSLConfiguration(mode: .verifyCa))
        #expect(cfg.isEnabled)
        #expect(cfg.verifiesCertificate)
        #expect(cfg.verifiesHostname == false)
    }

    @Test("verifyIdentity verifies the certificate and the hostname")
    func verifyIdentity() {
        let cfg = RedisSSLConfig(SSLConfiguration(mode: .verifyIdentity))
        #expect(cfg.isEnabled)
        #expect(cfg.verifiesCertificate)
        #expect(cfg.verifiesHostname)
    }

    @Test("cert and key paths flow through unchanged")
    func pathPassthrough() {
        let ssl = SSLConfiguration(
            mode: .verifyCa,
            caCertificatePath: "/tmp/ca.pem",
            clientCertificatePath: "/tmp/client.crt",
            clientKeyPath: "/tmp/client.key"
        )
        let cfg = RedisSSLConfig(ssl)
        #expect(cfg.caCertificatePath == "/tmp/ca.pem")
        #expect(cfg.clientCertificatePath == "/tmp/client.crt")
        #expect(cfg.clientKeyPath == "/tmp/client.key")
    }
}

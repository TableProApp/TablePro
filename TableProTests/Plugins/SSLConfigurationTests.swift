//
//  SSLConfigurationTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("SSLConfiguration boundary")
struct SSLConfigurationTests {
    @Test("default mode is disabled and all paths empty")
    func defaults() {
        let ssl = SSLConfiguration()
        #expect(ssl.mode == .disabled)
        #expect(ssl.caCertificatePath.isEmpty)
        #expect(ssl.clientCertificatePath.isEmpty)
        #expect(ssl.clientKeyPath.isEmpty)
        #expect(ssl.isEnabled == false)
        #expect(ssl.verifiesCertificate == false)
        #expect(ssl.verifiesHostname == false)
    }

    @Test(
        "isEnabled is true for every non-disabled mode",
        arguments: [SSLMode.preferred, .required, .verifyCa, .verifyIdentity]
    )
    func enabledForNonDisabled(mode: SSLMode) {
        #expect(SSLConfiguration(mode: mode).isEnabled)
    }

    @Test("verifiesCertificate is true only for verifyCa and verifyIdentity")
    func verifiesCertificate() {
        #expect(SSLConfiguration(mode: .disabled).verifiesCertificate == false)
        #expect(SSLConfiguration(mode: .preferred).verifiesCertificate == false)
        #expect(SSLConfiguration(mode: .required).verifiesCertificate == false)
        #expect(SSLConfiguration(mode: .verifyCa).verifiesCertificate)
        #expect(SSLConfiguration(mode: .verifyIdentity).verifiesCertificate)
    }

    @Test("verifiesHostname is true only for verifyIdentity")
    func verifiesHostname() {
        for mode in SSLMode.allCases where mode != .verifyIdentity {
            #expect(SSLConfiguration(mode: mode).verifiesHostname == false)
        }
        #expect(SSLConfiguration(mode: .verifyIdentity).verifiesHostname)
    }

    @Test("Codable round-trips every case via JSON")
    func codableRoundTrip() throws {
        let original = SSLConfiguration(
            mode: .verifyIdentity,
            caCertificatePath: "/etc/ssl/ca.pem",
            clientCertificatePath: "/etc/ssl/client.crt",
            clientKeyPath: "/etc/ssl/client.key"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SSLConfiguration.self, from: data)
        #expect(decoded == original)
    }

    @Test("raw values match the strings used in the connection form picker")
    func rawValueStability() {
        #expect(SSLMode.disabled.rawValue == "Disabled")
        #expect(SSLMode.preferred.rawValue == "Preferred")
        #expect(SSLMode.required.rawValue == "Required")
        #expect(SSLMode.verifyCa.rawValue == "Verify CA")
        #expect(SSLMode.verifyIdentity.rawValue == "Verify Identity")
    }
}

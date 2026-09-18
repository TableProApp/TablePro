//
//  MSSQLFreeTDSConfigTests.swift
//  TableProTests
//

import Foundation
import TableProMSSQLCore
import TableProPluginKit
import Testing

@Suite("MSSQL FreeTDS config")
struct MSSQLFreeTDSConfigTests {
    private func configuration(
        verification: MSSQLCertificateVerification,
        caCertificatePath: String? = nil
    ) -> String {
        MSSQLFreeTDSConfig.configuration(
            host: "db.example.com",
            port: 1_433,
            encryptionFlag: "require",
            verification: verification,
            caCertificatePath: caCertificatePath
        )
    }

    @Test("Every SSL mode maps to the verification it advertises")
    func modeMapping() {
        #expect(MSSQLSSLMapping.certificateVerification(for: .disabled) == .none)
        #expect(MSSQLSSLMapping.certificateVerification(for: .preferred) == .none)
        #expect(MSSQLSSLMapping.certificateVerification(for: .required) == .none)
        #expect(MSSQLSSLMapping.certificateVerification(for: .verifyCa) == .chain)
        #expect(MSSQLSSLMapping.certificateVerification(for: .verifyIdentity) == .chainAndHostname)
    }

    @Test("Verify CA pins an authority but does not check the hostname")
    func verifyCaConfiguration() {
        let text = configuration(verification: .chain)

        #expect(text.contains("[\(MSSQLFreeTDSConfig.serverEntryName)]"))
        #expect(text.contains("host = db.example.com"))
        #expect(text.contains("port = 1433"))
        #expect(text.contains("encryption = require"))
        #expect(text.contains("ca file = \(MSSQLFreeTDSConfig.systemTrustStorePath)"))
        #expect(!text.contains("check certificate hostname"))
    }

    @Test("Verify Identity also checks the hostname")
    func verifyIdentityConfiguration() {
        let text = configuration(verification: .chainAndHostname)

        #expect(text.contains("ca file = "))
        #expect(text.contains("check certificate hostname = yes"))
    }

    @Test("A user supplied authority wins over the system trust store")
    func userSuppliedAuthority() {
        let text = configuration(verification: .chain, caCertificatePath: "/Users/me/corp-ca.pem")

        #expect(text.contains("ca file = /Users/me/corp-ca.pem"))
        #expect(!text.contains(MSSQLFreeTDSConfig.systemTrustStorePath))
    }

    @Test("A blank authority path falls back to the system trust store")
    func blankAuthorityFallsBack() {
        #expect(MSSQLFreeTDSConfig.authorityPath(userSupplied: nil) == MSSQLFreeTDSConfig.systemTrustStorePath)
        #expect(MSSQLFreeTDSConfig.authorityPath(userSupplied: "   ") == MSSQLFreeTDSConfig.systemTrustStorePath)
        #expect(MSSQLFreeTDSConfig.authorityPath(userSupplied: "/tmp/ca.pem") == "/tmp/ca.pem")
    }

    @Test("A non-verifying mode writes no authority line")
    func nonVerifyingConfiguration() {
        let text = configuration(verification: .none)

        #expect(!text.contains("ca file"))
        #expect(!text.contains("check certificate hostname"))
    }

    @Test("The system trust store is present on this machine")
    func systemTrustStoreExists() {
        #expect(FileManager.default.fileExists(atPath: MSSQLFreeTDSConfig.systemTrustStorePath))
    }
}

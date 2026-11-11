//
//  LibPQSSLMappingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct LibPQSSLMappingTests {
    @Test("disabled maps to disable")
    func disabled() {
        #expect(LibPQSSLMapping.sslmode(for: .disabled) == "disable")
    }

    @Test("preferred maps to prefer")
    func preferred() {
        #expect(LibPQSSLMapping.sslmode(for: .preferred) == "prefer")
    }

    @Test("required maps to require")
    func required() {
        #expect(LibPQSSLMapping.sslmode(for: .required) == "require")
    }

    @Test("verifyCa maps to verify-ca")
    func verifyCa() {
        #expect(LibPQSSLMapping.sslmode(for: .verifyCa) == "verify-ca")
    }

    @Test("verifyIdentity maps to verify-full")
    func verifyIdentity() {
        #expect(LibPQSSLMapping.sslmode(for: .verifyIdentity) == "verify-full")
    }

    private static let missingRootMessage = """
        root certificate file "/Users/test/.postgresql/root.crt" does not exist
        Either provide the file, use the system's trusted roots with sslrootcert=system, or change sslmode to disable \
        server certificate verification.
        """

    @Test("Verify CA with no CA file names the missing CA and the mode that needs none, never sslrootcert=system")
    func verifyCAWithoutACAExplainsTheMissingCA() throws {
        let error = try #require(
            LibPQSSLMapping.missingRootCertificateError(Self.missingRootMessage, sslConfig: SSLConfiguration(mode: .verifyCa))
        )

        #expect(error.message.contains("Verify CA needs the server's CA certificate"))
        #expect(error.message.contains("Verify Identity"))
        #expect(!error.message.contains("sslrootcert"))
    }

    @Test("libpq's text is kept for any other mode, for a chosen CA file, and for any other failure")
    func otherFailuresKeepLibpqText() {
        let otherModes = [SSLMode.verifyIdentity, .required, .preferred].map { SSLConfiguration(mode: $0) }
        for sslConfig in otherModes {
            #expect(LibPQSSLMapping.missingRootCertificateError(Self.missingRootMessage, sslConfig: sslConfig) == nil)
        }
        let withCA = SSLConfiguration(mode: .verifyCa, caCertificatePath: "/ca.pem")
        #expect(LibPQSSLMapping.missingRootCertificateError(Self.missingRootMessage, sslConfig: withCA) == nil)
        let refused = "connection to server at \"db\" failed: FATAL:  password authentication failed for user \"app\""
        #expect(LibPQSSLMapping.missingRootCertificateError(refused, sslConfig: SSLConfiguration(mode: .verifyCa)) == nil)
    }
}

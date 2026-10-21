import Foundation
import OracleNIO
@testable import TableProOracleCore
import Testing

struct OracleTLSMapperTests {
    private let missingPath = "/nonexistent/tablepro-oracle-tests/ca.pem"

    @Test func testDisabledModeNeverConsultsTheFilesystem() throws {
        let description = OracleTLSDescription(
            mode: .disabled,
            caCertificatePath: missingPath,
            clientCertificatePath: missingPath,
            clientKeyPath: missingPath
        )
        #expect(throws: Never.self) { try OracleTLSMapper.tls(for: description) }
    }

    @Test func testRequiredModeWithNoCertificatePathsUsesSystemTrustRoots() {
        #expect(throws: Never.self) { try OracleTLSMapper.tls(for: OracleTLSDescription(mode: .required)) }
    }

    @Test func testRequiredModeIgnoresCAPathBecauseItDoesNotVerify() {
        let description = OracleTLSDescription(mode: .required, caCertificatePath: missingPath)
        #expect(throws: Never.self) { try OracleTLSMapper.tls(for: description) }
    }

    @Test func testUnreadableCAPathThrowsCertificateUnavailable() {
        let description = OracleTLSDescription(mode: .verifyCA, caCertificatePath: missingPath)
        assertCertificateUnavailable(for: description, field: .certificateAuthority)
    }

    @Test func testUnreadableClientCertificateThrowsCertificateUnavailable() {
        let description = OracleTLSDescription(mode: .required, clientCertificatePath: missingPath)
        assertCertificateUnavailable(for: description, field: .clientCertificate)
    }

    @Test func testUnreadableClientKeyThrowsCertificateUnavailable() {
        let description = OracleTLSDescription(mode: .required, clientKeyPath: missingPath)
        assertCertificateUnavailable(for: description, field: .clientKey)
    }

    @Test func testEmptyPathsAreTreatedAsAbsent() {
        let description = OracleTLSDescription(
            mode: .verifyIdentity,
            caCertificatePath: "",
            clientCertificatePath: "",
            clientKeyPath: ""
        )
        #expect(description.caCertificatePath == nil)
        #expect(description.clientCertificatePath == nil)
        #expect(description.clientKeyPath == nil)
        #expect(throws: Never.self) { try OracleTLSMapper.tls(for: description) }
    }

    @Test func testVerifyCAWithNoCAPathThrowsCertificateAuthorityRequired() {
        for path in [nil, "", "   "] {
            let description = OracleTLSDescription(mode: .verifyCA, caCertificatePath: path)
            if let error = #expect(throws: (any Error).self, performing: { try OracleTLSMapper.tls(for: description) }) {
                #expect(error as? OracleCoreError == .certificateAuthorityRequired)
            }
        }
    }

    @Test func testVerifyCANoCARefusalWinsOverUnreadableClientMaterial() {
        let description = OracleTLSDescription(
            mode: .verifyCA,
            clientCertificatePath: missingPath,
            clientKeyPath: missingPath
        )
        if let error = #expect(throws: (any Error).self, performing: { try OracleTLSMapper.tls(for: description) }) {
            #expect(error as? OracleCoreError == .certificateAuthorityRequired)
        }
    }

    @Test func testVerifyIdentityWithNoCAPathStillConnectsOverTLS() throws {
        let description = OracleTLSDescription(mode: .verifyIdentity)
        #expect(try OracleTLSMapper.tls(for: description).sslContext != nil)
    }

    @Test func testWhitespaceOnlyPathsAreTreatedAsAbsent() {
        let description = OracleTLSDescription(
            mode: .verifyIdentity,
            caCertificatePath: "  ",
            clientCertificatePath: " ",
            clientKeyPath: "\t"
        )
        #expect(description.caCertificatePath == nil)
        #expect(description.clientCertificatePath == nil)
        #expect(description.clientKeyPath == nil)
    }

    @Test func testCertificateVerificationPerMode() {
        #expect(OracleTLSMapper.certificateVerification(for: .verifyIdentity) == .fullVerification)
        #expect(OracleTLSMapper.certificateVerification(for: .verifyCA) == .noHostnameVerification)
        #expect(OracleTLSMapper.certificateVerification(for: .required) == .none)
        #expect(OracleTLSMapper.certificateVerification(for: .disabled) == .none)
    }

    @Test func testTunneledServerNameReachesTheDriverConfiguration() throws {
        let options = OracleConnectionOptions(
            host: "127.0.0.1",
            port: 49_152,
            user: "scott",
            password: "tiger",
            tls: OracleTLSDescription(mode: .verifyIdentity, serverName: "db.example.com")
        )
        let configuration = try OracleCoreConnection.configuration(for: options)
        #expect(configuration.options.tlsServerName == "db.example.com")
        #expect(configuration.serverNameForTLS == "db.example.com")
        #expect(configuration.host == "127.0.0.1")
    }

    @Test func testNoServerNameLeavesTheDriverToNameTheDialedHost() throws {
        let tunneled = try OracleCoreConnection.configuration(for: OracleConnectionOptions(
            host: "127.0.0.1",
            user: "scott",
            password: "tiger",
            tls: OracleTLSDescription(mode: .verifyIdentity)
        ))
        #expect(tunneled.options.tlsServerName == nil)
        #expect(tunneled.serverNameForTLS == nil)

        let direct = try OracleCoreConnection.configuration(for: OracleConnectionOptions(
            host: "db.example.com",
            user: "scott",
            password: "tiger",
            tls: OracleTLSDescription(mode: .verifyIdentity)
        ))
        #expect(direct.options.tlsServerName == nil)
        #expect(direct.serverNameForTLS == "db.example.com")
    }

    @Test func testAnAddressIsNeverSentAsTheServerName() {
        for address in ["10.0.0.5", "::1", "fe80::1"] {
            let description = OracleTLSDescription(mode: .verifyIdentity, serverName: address)
            #expect(OracleTLSMapper.serverName(for: description) == nil, "\(address)")
        }
        #expect(OracleTLSMapper.serverName(for: OracleTLSDescription(mode: .required, serverName: "  ")) == nil)
        #expect(OracleTLSMapper.serverName(for: OracleTLSDescription(mode: .required, serverName: "db.example.com")) == "db.example.com")
    }

    private func assertCertificateUnavailable(
        for description: OracleTLSDescription,
        field: OracleCertificateField,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        if let error = #expect(throws: (any Error).self, sourceLocation: sourceLocation, performing: { try OracleTLSMapper.tls(for: description) }) {
            guard case .certificateUnavailable(let thrownField, let path) = error as? OracleCoreError else {
                Issue.record("expected certificateUnavailable, got \(error)", sourceLocation: sourceLocation)
                return
            }
            #expect(thrownField == field, sourceLocation: sourceLocation)
            #expect(path == missingPath, sourceLocation: sourceLocation)
        }
    }
}

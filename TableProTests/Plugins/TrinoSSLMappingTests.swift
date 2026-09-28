//
//  TrinoSSLMappingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProTrinoCore
import Testing

struct TrinoSSLMappingTests {
    private let verifyCANeedsCertificate = TrinoError.invalidConfiguration(
        "Verify CA needs a CA certificate. On the connection's Network tab, choose the CA certificate "
            + "that signed the server's certificate, or set SSL Mode to Verify Identity."
    )

    @Test("Verify CA with no CA certificate is refused before any connection is made")
    func verifyCAWithoutCertificateIsRefused() {
        for path in ["", "   "] {
            #expect(throws: verifyCANeedsCertificate) {
                try TrinoSSLMapping.tlsOptions(for: SSLConfiguration(mode: .verifyCa, caCertificatePath: path))
            }
        }
    }

    @Test("Verify Identity with no CA certificate checks the system trust store")
    func verifyIdentityWithoutCertificateUsesSystemTrust() throws {
        let options = try TrinoSSLMapping.tlsOptions(for: SSLConfiguration(mode: .verifyIdentity))

        #expect(options.mode == .full)
        #expect(options.anchorCertificate == nil)
        #expect(options.clientCredential == nil)
    }

    @Test("A client certificate is never loaded with SSL off, and a key with no certificate means no certificate")
    func clientCertificateIsIgnoredWhenUnused() throws {
        let disabled = SSLConfiguration(
            mode: .disabled,
            clientCertificatePath: "/nonexistent/client.pem",
            clientKeyPath: "/nonexistent/client.key"
        )
        let keyOnly = SSLConfiguration(mode: .required, clientKeyPath: "/nonexistent/client.key")

        #expect(try TrinoSSLMapping.clientCredential(for: disabled) == nil)
        #expect(try TrinoSSLMapping.clientCredential(for: keyOnly) == nil)
    }

    @Test("A client certificate with no key is refused")
    func certificateWithoutKeyIsRefused() {
        let ssl = SSLConfiguration(mode: .required, clientCertificatePath: "/nonexistent/client.pem")

        #expect(throws: TrinoError.invalidConfiguration(
            "A client certificate needs its client key. On the connection's Network tab, choose the "
                + "client key, or clear the client certificate."
        )) {
            try TrinoSSLMapping.clientCredential(for: ssl)
        }
    }

    @Test("A client certificate file that cannot be read is named in the refusal")
    func unreadableCertificateIsNamed() {
        let ssl = SSLConfiguration(
            mode: .verifyIdentity,
            clientCertificatePath: " /nonexistent/client.pem ",
            clientKeyPath: "/nonexistent/client.key"
        )

        #expect(throws: TrinoError.invalidConfiguration("The client certificate at /nonexistent/client.pem could not be read.")) {
            try TrinoSSLMapping.clientCredential(for: ssl)
        }
    }

    @Test("A password or access token over plain HTTP is refused with what to change")
    func plaintextRefusals() {
        #expect(TrinoCredentialKind.password.plaintextRefusal == .invalidConfiguration(
            "A password is sent only over TLS, and SSL Mode is Disabled. Set SSL Mode to Verify Identity, "
                + "or clear the password if the cluster has no authentication."
        ))
        #expect(TrinoCredentialKind.accessToken.plaintextRefusal == .invalidConfiguration(
            "An access token is sent only over TLS, and SSL Mode is Disabled. Set SSL Mode to Verify "
                + "Identity, or clear the Access Token if the cluster has no authentication."
        ))
        #expect(TrinoError.credentialsRequireTLS(.password).connectionFailure as? TrinoError
            == TrinoCredentialKind.password.plaintextRefusal)
    }

    @Test("A redirect at connect reads as advice the connection form can show")
    func redirectAdvice() {
        let noAddress = TrinoError.redirected(statusCode: 300, location: nil, advice: .checkAddress)
        let turnOnTLS = TrinoError.redirected(
            statusCode: 308,
            location: "https://trino.example.com/v1/statement",
            advice: .turnOnTLS(port: 443)
        )
        let checkAddress = TrinoError.redirected(
            statusCode: 302,
            location: "https://sso.example.com/auth",
            advice: .checkAddress
        )

        #expect(noAddress.connectionFailure as? TrinoError == .invalidConfiguration(
            "The server answered with HTTP 300 and no address. Trino never redirects, so a proxy in "
                + "front of it sent this. Check the host, port and SSL Mode."
        ))
        #expect(turnOnTLS.connectionFailure as? TrinoError == .invalidConfiguration(
            "The server redirected the request to https://trino.example.com/v1/statement, which needs HTTPS. "
                + "Set Port to 443 and SSL Mode to Verify Identity."
        ))
        #expect(checkAddress.connectionFailure as? TrinoError == .invalidConfiguration(
            "The server redirected the request to https://sso.example.com/auth. TablePro does not follow "
                + "redirects, and Trino never sends one, so a proxy in front of it did. Check the host, port and SSL Mode."
        ))
    }

    @Test("A missing client certificate asks for one, and a rejected one says the server did not accept it")
    func clientCertificateFailures() {
        let required = TrinoError.tlsHandshakeFailed(kind: .clientCertificateRequired, serverMessage: "Unauthorized")
        let rejected = TrinoError.tlsHandshakeFailed(
            kind: .clientCertificateRejected,
            serverMessage: "The network connection was lost."
        )

        guard case .clientCertRequired(let requiredMessage)? = required.connectionFailure as? SSLHandshakeError else {
            Issue.record("Expected clientCertRequired, got \(required.connectionFailure)")
            return
        }
        #expect(requiredMessage == "Unauthorized")
        guard case .unknown(let rejectedMessage)? = rejected.connectionFailure as? SSLHandshakeError else {
            Issue.record("Expected an unknown TLS failure, got \(rejected.connectionFailure)")
            return
        }
        #expect(rejectedMessage == "The server did not accept the client certificate. The network connection was lost.")
    }

    @Test("Other Trino errors reach the connection form unchanged")
    func otherErrorsPassThrough() {
        let error = TrinoError.authenticationFailed("Access Denied: Invalid credentials")

        #expect(error.connectionFailure as? TrinoError == error)
    }
}

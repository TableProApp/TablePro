import Foundation
import TableProDuckDBCore
import Testing

// Measured on DuckDB v2.0.0 with quack f96420ed and httpfs 77392a7, verbatim.
private let untrusted = "IO Error: Failed to send message: IO Error: SSL peer certificate or SSH remote key was not OK "
    + "error for HTTP POST to 'https://192.168.170.165:9494/quack'"
private let plainToTLS = "IO Error: Failed to send message: IO Error: Unsupported protocol error for HTTP POST to "
    + "'http://127.0.0.1:9494/quack'"
private let tlsToPlain = "IO Error: Failed to send message: IO Error: SSL connect error error for HTTP POST to "
    + "'https://172.25.144.180:9494/quack'"
private let pinnedToPlain = "IO Error: Failed to send message: SSL connection failed error for HTTP POST to "
    + "'https://172.25.144.180:9494/quack'"
private let pinMismatch = "IO Error: Failed to send message: the certificate presented by https://172.25.144.180:9494 "
    + "does not match the pinned ssl_fingerprint"
private let derCA = "IO Error: Failed to send message: IO Error: Problem with the SSL CA cert (path? access rights?) "
    + "error for HTTP POST to 'https://172.25.144.180:9494/quack'"

private struct DuckDBText: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

struct QuackConnectErrorClassifierTests {
    @Test("An untrusted or misnamed certificate names the three fields and says the keychain is not read")
    func untrustedCertificate() throws {
        let error = try #require(QuackConnectErrorClassifier.classify(message: untrusted, tunneled: false))
        #expect(error == .certificateNotTrusted(detail: untrusted))
        let message = try #require(error.errorDescription)
        #expect(message.contains("SSL Mode"))
        #expect(message.contains("CA Certificate"))
        #expect(message.contains("Certificate Fingerprint"))
        #expect(message.contains("keychain"))
        #expect(message.contains(untrusted))
    }

    @Test("Plain HTTP to a TLS server asks for a TLS mode, never Verify Identity through a tunnel")
    func plainHTTPToTLSServer() throws {
        let direct = try #require(QuackConnectErrorClassifier.classify(message: plainToTLS, tunneled: false))
        #expect(direct == .serverExpectsHTTPS(detail: plainToTLS, tunneled: false))
        let directMessage = try #require(direct.errorDescription)
        #expect(directMessage.contains("SSL Mode"))
        #expect(directMessage.contains("Verify Identity"))
        #expect(directMessage.contains("Verify Fingerprint"))

        let tunneled = try #require(QuackConnectErrorClassifier.classify(message: plainToTLS, tunneled: true))
        #expect(tunneled == .serverExpectsHTTPS(detail: plainToTLS, tunneled: true))
        let tunneledMessage = try #require(tunneled.errorDescription)
        #expect(!tunneledMessage.contains("Verify Identity"))
        #expect(tunneledMessage.contains("Verify Fingerprint"))
        #expect(tunneledMessage.contains("Required (skip verify)"))
    }

    @Test("HTTPS to a plain HTTP server, from curl or the pinned client, points at Disabled",
          arguments: [tlsToPlain, pinnedToPlain])
    func tlsToPlainServer(text: String) throws {
        let error = try #require(QuackConnectErrorClassifier.classify(message: text, tunneled: false))
        #expect(error == .serverExpectsPlainHTTP(detail: text))
        let message = try #require(error.errorDescription)
        #expect(message.contains("SSL Mode"))
        #expect(message.contains("Disabled"))
    }

    @Test("A pin the server does not match names Certificate Fingerprint")
    func pinMismatchNamesTheField() throws {
        let error = try #require(QuackConnectErrorClassifier.classify(message: pinMismatch, tunneled: true))
        #expect(error == .fingerprintMismatch(detail: pinMismatch))
        #expect(try #require(error.errorDescription).contains("Certificate Fingerprint"))
    }

    @Test("A CA file curl cannot read names CA Certificate and PEM")
    func unreadableCA() throws {
        let error = try #require(QuackConnectErrorClassifier.classify(message: derCA, tunneled: false))
        #expect(error == .caCertificateRejected(detail: derCA))
        let message = try #require(error.errorDescription)
        #expect(message.contains("CA Certificate"))
        #expect(message.contains("PEM"))
    }

    @Test("Any other failure keeps DuckDB's own text", arguments: [
        "Invalid Input Error: Authentication failed",
        "Invalid Input Error: Quack secret \"pinonly\" does not contain a token",
        "IO Error: Failed to send message: IO Error: Cannot open file \"/nonexistent/ca.pem\": No such file or directory",
        "Catalog Error: SET schema: No catalog + schema named \"remotedb\" found",
    ])
    func otherFailuresPassThrough(text: String) {
        #expect(QuackConnectErrorClassifier.classify(message: text, tunneled: false) == nil)
        #expect(QuackConnectErrorClassifier.classify(DuckDBText(text: text), tunneled: false) == nil)
    }

    @Test("A driver error is read through its description, and a refusal passes through as it is")
    func classifiesErrors() {
        #expect(QuackConnectErrorClassifier.classify(DuckDBText(text: untrusted), tunneled: false)
            == .certificateNotTrusted(detail: untrusted))
        #expect(QuackConnectErrorClassifier.classify(QuackConnectError.tunneledVerifyIdentity, tunneled: true)
            == .tunneledVerifyIdentity)
    }

    @Test("Each refusal before dialing names the setting to change")
    func refusalMessages() throws {
        let automatic = try #require(QuackConnectError.tunneledAutomatic(server: "db.example.com").errorDescription)
        #expect(automatic.contains("db.example.com"))
        #expect(automatic.contains("SSL Mode"))
        #expect(automatic.contains("Verify Fingerprint"))
        let identity = try #require(QuackConnectError.tunneledVerifyIdentity.errorDescription)
        #expect(identity.contains("Verify Identity"))
        #expect(identity.contains("Verify Fingerprint"))
        #expect(try #require(QuackConnectError.missingFingerprint.errorDescription).contains("Certificate Fingerprint"))
        #expect(try #require(QuackConnectError.invalidFingerprint.errorDescription).contains("Certificate Fingerprint"))
    }
}

//
//  ClickHouseTLSConfigurationTests.swift
//  TableProTests
//

import Foundation
import Security
import TableProPluginKit
import Testing

@testable import TablePro

struct ClickHouseTLSConfigurationTests {
    private func configuration(_ mode: SSLMode, caPath: String = "") -> SSLConfiguration {
        SSLConfiguration(mode: mode, caCertificatePath: caPath)
    }

    private func refusal(_ ssl: SSLConfiguration) -> String? {
        do {
            _ = try ClickHouseTLSDelegate.make(for: ssl)
            return nil
        } catch let error as ClickHouseError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    @Test("Verify CA with no CA certificate is refused before any request, since it checks no hostname")
    func verifyCAWithoutCAIsRefused() {
        #expect(refusal(configuration(.verifyCa)) == ClickHouseError.verifyCaNeedsCertificate.message)
        #expect(refusal(configuration(.verifyCa, caPath: "   ")) == ClickHouseError.verifyCaNeedsCertificate.message)
    }

    @Test("Verify Identity with no CA certificate checks the system trust store and is allowed")
    func verifyIdentityWithoutCAIsAllowed() throws {
        #expect(try ClickHouseTLSDelegate.make(for: configuration(.verifyIdentity)) == nil)
        #expect(try ClickHouseTLSDelegate.make(for: configuration(.disabled)) == nil)
        #expect(try ClickHouseTLSDelegate.make(for: configuration(.required)) != nil)
    }

    @Test("A CA path that does not load is refused in both verify modes rather than widened to the system roots")
    func unreadableCAIsRefused() throws {
        let missing = "/nonexistent/ca-\(UUID().uuidString).pem"
        let notACertificate = FileManager.default.temporaryDirectory
            .appendingPathComponent("ca-\(UUID().uuidString).pem")
        try Data("not a certificate".utf8).write(to: notACertificate)
        defer { try? FileManager.default.removeItem(at: notACertificate) }
        for mode in [SSLMode.verifyCa, .verifyIdentity] {
            for path in [missing, notACertificate.path] {
                #expect(refusal(configuration(mode, caPath: path))?.contains(path) == true, "\(mode) \(path)")
            }
        }
    }

    private static let caCertificatePEM = """
        -----BEGIN CERTIFICATE-----
        MIIBKDCBzgIJAItYmqrR5A5nMAoGCCqGSM49BAMCMBsxGTAXBgNVBAMMEFRhYmxl
        UHJvIFRlc3QgQ0EwIBcNMjYwOTI4MTU1MzMyWhgPMjEyNjA5MDQxNTUzMzJaMBsx
        GTAXBgNVBAMMEFRhYmxlUHJvIFRlc3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMB
        BwNCAASaYfImiB+IzxPGowAQoY7FJ+pMBUH44UT+xAYLv5daFRxN2UyT9OVoblbw
        eckn8xKUHUudi7CXcAYRCK37s4lzMAoGCCqGSM49BAMCA0kAMEYCIQCSluC20xFq
        Low0L94hZ8kUnPyvB0Lr+BaeqDo8XQD2+wIhAJvEM/BlLmzZoWm9acV24GaQ8/uy
        cC5Nd9tqoj6nWEbU
        -----END CERTIFICATE-----
        """

    @Test("A readable PEM CA certificate builds a verifying delegate in both verify modes")
    func readableCABuildsDelegate() throws {
        let caFile = FileManager.default.temporaryDirectory.appendingPathComponent("ca-\(UUID().uuidString).pem")
        try Data(Self.caCertificatePEM.utf8).write(to: caFile)
        defer { try? FileManager.default.removeItem(at: caFile) }
        for mode in [SSLMode.verifyCa, .verifyIdentity] {
            #expect(try ClickHouseTLSDelegate.make(for: configuration(mode, caPath: caFile.path)) != nil, "\(mode)")
        }
    }

    private static let clientCertificatePEM = """
        -----BEGIN CERTIFICATE-----
        MIIBRjCB7AIJAI8IxGRVwB2sMAoGCCqGSM49BAMCMCoxKDAmBgNVBAMMH1RhYmxl
        UHJvIENsaWNrSG91c2UgVGVzdCBDbGllbnQwIBcNMjYwOTMwMDgwODM5WhgPMjEy
        NjA5MDYwODA4MzlaMCoxKDAmBgNVBAMMH1RhYmxlUHJvIENsaWNrSG91c2UgVGVz
        dCBDbGllbnQwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAR4MsJgLIbNVUdTp1AI
        +UI59GxEZNE+2GS37Dq8sEluUP+MK4lJmP5eamZoDI1FJgXuol/6/j99J3x9tWSo
        2JCGMAoGCCqGSM49BAMCA0kAMEYCIQDo8UPcX3AbSM4vSga4ZmNz8l1yt7PI0i5+
        pis0886smAIhALdWMO0Vi6SA4NEJUr3EeQyye3rrS9j43ZMTMhXxovX/
        -----END CERTIFICATE-----
        """

    private static let clientKeyPEM = """
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgyzfBMM5MAZs5n7VW
        ZAMWdxn0FdlZiRKhL2eWOwXfs96hRANCAAR4MsJgLIbNVUdTp1AI+UI59GxEZNE+
        2GS37Dq8sEluUP+MK4lJmP5eamZoDI1FJgXuol/6/j99J3x9tWSo2JCG
        -----END PRIVATE KEY-----
        """

    private struct ClientIdentityFiles {
        let certificate: URL
        let key: URL

        init() throws {
            let folder = FileManager.default.temporaryDirectory
            certificate = folder.appendingPathComponent("client-\(UUID().uuidString).pem")
            key = folder.appendingPathComponent("client-\(UUID().uuidString).key")
            try Data(ClickHouseTLSConfigurationTests.clientCertificatePEM.utf8).write(to: certificate)
            try Data(ClickHouseTLSConfigurationTests.clientKeyPEM.utf8).write(to: key)
        }

        func remove() {
            try? FileManager.default.removeItem(at: certificate)
            try? FileManager.default.removeItem(at: key)
        }
    }

    private final class IgnoringChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private final class ServerTrustProtectionSpace: URLProtectionSpace, @unchecked Sendable {
        private let trust: SecTrust

        init(trust: SecTrust) {
            self.trust = trust
            super.init(
                host: "clickhouse.example.com",
                port: 8_443,
                protocol: NSURLProtectionSpaceHTTPS,
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodServerTrust
            )
        }

        required init?(coder: NSCoder) {
            nil
        }

        override var serverTrust: SecTrust? { trust }
    }

    private func fixtureServerTrust() throws -> SecTrust {
        let base64 = Self.clientCertificatePEM
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        let der = try #require(Data(base64Encoded: base64))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            certificate,
            SecPolicyCreateSSL(true, "clickhouse.example.com" as CFString),
            &trust
        )
        try #require(status == errSecSuccess)
        return try #require(trust)
    }

    private func answer(
        _ authenticationMethod: String,
        with delegate: ClickHouseTLSDelegate
    ) -> (disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?) {
        answer(
            URLProtectionSpace(
                host: "clickhouse.example.com",
                port: 8_443,
                protocol: NSURLProtectionSpaceHTTPS,
                realm: nil,
                authenticationMethod: authenticationMethod
            ),
            with: delegate
        )
    }

    private func answer(
        _ protectionSpace: URLProtectionSpace,
        with delegate: ClickHouseTLSDelegate
    ) -> (disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?) {
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: IgnoringChallengeSender()
        )
        var answer: (URLSession.AuthChallengeDisposition, URLCredential?) = (.rejectProtectionSpace, nil)
        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            answer = (disposition, credential)
        }
        return answer
    }

    @Test("A client certificate and key are presented when the server asks for one, in every TLS mode")
    func clientIdentityAnswersTheCertificateChallenge() throws {
        let files = try ClientIdentityFiles()
        defer { files.remove() }
        for mode in [SSLMode.verifyIdentity, .required, .preferred] {
            let ssl = SSLConfiguration(
                mode: mode,
                clientCertificatePath: files.certificate.path,
                clientKeyPath: files.key.path
            )
            let delegate = try #require(try ClickHouseTLSDelegate.make(for: ssl), "\(mode)")

            let answered = answer(NSURLAuthenticationMethodClientCertificate, with: delegate)

            #expect(answered.disposition == .useCredential, "\(mode)")
            #expect(answered.credential?.identity != nil, "\(mode)")
        }
    }

    @Test("Verify Identity with only a client identity still leaves the server's certificate to the system")
    func clientIdentityKeepsSystemServerTrust() throws {
        let files = try ClientIdentityFiles()
        defer { files.remove() }
        let trust = try fixtureServerTrust()
        let identityOnly = try #require(try ClickHouseTLSDelegate.make(for: SSLConfiguration(
            mode: .verifyIdentity,
            clientCertificatePath: files.certificate.path,
            clientKeyPath: files.key.path
        )))
        let skipVerify = try #require(try ClickHouseTLSDelegate.make(for: SSLConfiguration(
            mode: .required,
            clientCertificatePath: files.certificate.path,
            clientKeyPath: files.key.path
        )))

        #expect(answer(ServerTrustProtectionSpace(trust: trust), with: skipVerify).disposition == .useCredential)
        #expect(
            answer(ServerTrustProtectionSpace(trust: trust), with: identityOnly).disposition == .performDefaultHandling
        )
    }

    @Test("A certificate challenge with no client identity configured is left to the system")
    func noClientIdentityLeavesTheChallenge() throws {
        let delegate = try #require(try ClickHouseTLSDelegate.make(for: configuration(.required)))

        let answered = answer(NSURLAuthenticationMethodClientCertificate, with: delegate)

        #expect(answered.disposition == .performDefaultHandling)
        #expect(answered.credential == nil)
    }

    @Test("SSL off presents no client identity even when the paths are filled in")
    func disabledPresentsNothing() throws {
        let files = try ClientIdentityFiles()
        defer { files.remove() }
        let ssl = SSLConfiguration(
            mode: .disabled,
            clientCertificatePath: files.certificate.path,
            clientKeyPath: files.key.path
        )

        #expect(try ClickHouseTLSDelegate.make(for: ssl) == nil)
    }

    @Test("A client certificate without its key, or a key that does not load, is refused before any request")
    func unusableClientIdentityIsRefused() throws {
        let files = try ClientIdentityFiles()
        defer { files.remove() }
        let withoutKey = SSLConfiguration(mode: .verifyIdentity, clientCertificatePath: files.certificate.path)
        let unreadableKey = SSLConfiguration(
            mode: .verifyIdentity,
            clientCertificatePath: files.certificate.path,
            clientKeyPath: files.certificate.path
        )

        #expect(refusal(withoutKey)?.contains("client key") == true)
        #expect(refusal(unreadableKey)?.contains(files.certificate.path) == true)
    }

    @Test("A certificate that fails its host check is reported as a hostname mismatch, anything else as untrusted")
    func refusalKinds() {
        let hostname = CFErrorCreate(nil, NSOSStatusErrorDomain as CFString, CFIndex(errSecHostNameMismatch), nil)
        let untrusted = CFErrorCreate(nil, NSOSStatusErrorDomain as CFString, CFIndex(errSecNotTrusted), nil)
        guard case .hostnameMismatch = ClickHouseTLSDelegate.refusal(for: hostname) else {
            Issue.record("Expected a hostname mismatch")
            return
        }
        guard case .untrustedCertificate = ClickHouseTLSDelegate.refusal(for: untrusted) else {
            Issue.record("Expected an untrusted certificate")
            return
        }
    }
}

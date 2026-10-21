import Foundation
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import TableProTLSTestFixtures
import Testing

// Against the Connector/C 3.4.4 the app links. The fixture certificate names localhost and 127.0.0.1.
@Suite(.timeLimit(.minutes(1)))
struct MySQLTLSPolicyTests {
    private static let password = "plain-password"

    @Test("Required refuses a server without TLS before the password, even one that asks for it in cleartext")
    func requiredRefusesPlaintextServer() async throws {
        let server = try FakeMySQLServer(identity: nil, asksForCleartext: true)
        defer { server.close() }
        async let session = server.serveOneSession()

        let error = await #expect(throws: SSLHandshakeError.self) {
            try await driver(port: server.port, ssl: DriverSSLConfiguration(mode: .require)).connect()
        }

        guard case .serverRequiresPlaintext = error else {
            Issue.record("Expected serverRequiresPlaintext, got \(String(describing: error))")
            return
        }
        let served = await session
        #expect(!served.sawLogin)
        #expect(served.cleartextPassword == nil)
        #expect(!served.sawInPlaintext(Self.password))
    }

    @Test("Preferred still signs in to a server without TLS, in plaintext")
    func preferredFallsBackToPlaintext() async throws {
        let server = try FakeMySQLServer(identity: nil)
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = driver(port: server.port, ssl: DriverSSLConfiguration(mode: .require, isPreferred: true))

        try await driver.connect()
        try await driver.disconnect()

        let served = await session
        #expect(!served.encrypted)
        #expect(served.loggedIn)
    }

    @Test("Preferred retries in plaintext after a failed TLS handshake, as the Mac does")
    func preferredRetriesAfterBrokenHandshake() async throws {
        let server = try FakeMySQLServer(identity: nil, breaksHandshake: true)
        defer { server.close() }
        async let sessions = server.serve(sessions: 2)
        let driver = driver(port: server.port, ssl: DriverSSLConfiguration(mode: .require, isPreferred: true))

        try await driver.connect()
        try await driver.disconnect()

        let served = await sessions
        #expect(served[0].askedForTLS)
        #expect(!served[0].sawLogin)
        #expect(!served[1].askedForTLS)
        #expect(served[1].loggedIn)
    }

    @Test("Required encrypts without checking the certificate")
    func requiredAcceptsAnyCertificate() async throws {
        let server = try FakeMySQLServer(identity: .rogue)
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = driver(port: server.port, ssl: DriverSSLConfiguration(mode: .require))

        try await driver.connect()
        try await driver.disconnect()

        let served = await session
        #expect(served.encrypted)
        #expect(served.loggedIn)
    }

    @Test(
        "Behind a tunnel, Verify Identity checks the server's own name, not 127.0.0.1",
        arguments: [("localhost", true), ("db.example.com", false)]
    )
    func tunnelVerifyIdentityChecksServerName(serverName: String, connects: Bool) async throws {
        let fixtures = try CertificateFiles()
        defer { fixtures.remove() }
        let server = try FakeMySQLServer(identity: .localhost, asksForCleartext: true)
        defer { server.close() }
        async let session = server.serveOneSession()
        let ssl = DriverSSLConfiguration(mode: .verifyFull, caCertificatePath: fixtures.authority, serverName: serverName)

        let outcome = await connectOutcome(port: server.port, ssl: ssl)

        let served = await session
        #expect((outcome == nil) == connects)
        #expect(served.loggedIn == connects)
        if !connects {
            guard case .hostnameMismatch = outcome as? SSLHandshakeError else {
                Issue.record("Expected hostnameMismatch, got \(String(describing: outcome))")
                return
            }
            #expect(served.cleartextPassword == nil)
        }
    }

    @Test("Verify CA checks the chain but not the name, behind a tunnel too")
    func verifyCASkipsTheName() async throws {
        let fixtures = try CertificateFiles()
        defer { fixtures.remove() }
        let server = try FakeMySQLServer(identity: .localhost)
        defer { server.close() }
        async let session = server.serveOneSession()
        let ssl = DriverSSLConfiguration(
            mode: .verifyCa, caCertificatePath: fixtures.authority, serverName: "db.example.com"
        )

        let outcome = await connectOutcome(port: server.port, ssl: ssl)

        let served = await session
        #expect(outcome == nil)
        #expect(served.loggedIn)
    }

    @Test(
        "Behind a tunnel, a certificate no CA vouches for is refused, which a 127.0.0.1 dial alone would forgive",
        arguments: [TableProModels.SSLConfiguration.SSLMode.verifyCa, .verifyFull]
    )
    func tunnelRefusesUntrustedCertificate(mode: TableProModels.SSLConfiguration.SSLMode) async throws {
        let server = try FakeMySQLServer(identity: .rogue, asksForCleartext: true)
        defer { server.close() }
        async let session = server.serveOneSession()

        let outcome = await connectOutcome(
            port: server.port,
            ssl: DriverSSLConfiguration(mode: mode, serverName: "rogue")
        )

        let served = await session
        #expect(outcome != nil)
        #expect(!served.loggedIn)
        #expect(served.cleartextPassword == nil)
    }

    @Test("A token session on Preferred is raised to Required, so it never falls back")
    func tokenOnPreferredIsRequired() {
        let preferred = DriverSSLConfiguration(mode: .require, isPreferred: true)
        #expect(MySQLTLSPolicy(preferred) == .preferred)
        #expect(MySQLTLSPolicy(preferred, signsInWithToken: true) == .required)
        #expect(MySQLTLSPolicy(.disabled, signsInWithToken: true) == .required)
        #expect(MySQLTLSPolicy(.disabled) == .disabled)
    }

    private func driver(port: Int, ssl: DriverSSLConfiguration) -> MySQLDriver {
        MySQLDriver(host: "127.0.0.1", port: port, user: "app", password: Self.password, database: "", ssl: ssl)
    }

    private func connectOutcome(port: Int, ssl: DriverSSLConfiguration) async -> Error? {
        let driver = driver(port: port, ssl: ssl)
        do {
            try await driver.connect()
            try await driver.disconnect()
            return nil
        } catch {
            return error
        }
    }
}

private struct CertificateFiles {
    let directory: URL
    let authority: String

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MySQLTLSPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("ca.pem")
        try TLSTestFixtures.data(TLSTestFixtures.caCertificate).write(to: url)
        authority = url.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

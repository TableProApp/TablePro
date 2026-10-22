import CMariaDB
import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MySQLTokenSignInTests {
    private static let token = "signed-token"

    @Test("A token is never sent to a server that does not offer TLS, even one that asks for it in cleartext")
    func tokenNeverReachesAPlaintextServer() async throws {
        let server = try FakeMySQLServer(identity: nil, asksForCleartext: true)
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = tokenDriver(port: server.port)

        let error = await #expect(throws: IAMSignInError.self) { try await driver.connect() }

        #expect(error == .encryptionNotEstablished)
        let served = await session
        #expect(!served.sawInPlaintext(Self.token))
        #expect(!served.loggedIn)
    }

    @Test("A token session answers the cleartext request inside TLS, without a CA to check the certificate against")
    func tokenTravelsInsideTLS() async throws {
        let server = try FakeMySQLServer(identity: .localhost, asksForCleartext: true)
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = tokenDriver(port: server.port)

        try await driver.connect()
        try await driver.disconnect()

        let served = await session
        #expect(served.encrypted)
        #expect(served.cleartextPassword == Self.token)
        #expect(!served.sawInPlaintext(Self.token))
        #expect(served.loggedIn)
        #expect(served.quit)
    }

    @Test("Only a token session refused for a server without TLS is an encryption failure")
    func connectFailure() {
        let sslError = UInt32(CR_SSL_CONNECTION_ERROR)
        let offersTLS = UInt(CLIENT_SSL)

        #expect(
            MySQLTokenSignIn.connectFailure(signsInWithToken: true, errorCode: sslError, serverCapabilities: 0)
                == .encryptionNotEstablished
        )
        #expect(
            MySQLTokenSignIn.connectFailure(signsInWithToken: true, errorCode: sslError, serverCapabilities: offersTLS)
                == nil
        )
        #expect(
            MySQLTokenSignIn.connectFailure(signsInWithToken: false, errorCode: sslError, serverCapabilities: 0) == nil
        )
        #expect(
            MySQLTokenSignIn.connectFailure(
                signsInWithToken: true,
                errorCode: UInt32(CR_CONN_HOST_ERROR),
                serverCapabilities: 0
            ) == nil
        )
    }

    private func tokenDriver(port: Int) -> MySQLDriver {
        MySQLDriver(
            host: "127.0.0.1",
            port: port,
            user: "iam_user",
            password: Self.token,
            database: "",
            ssl: DriverSSLConfiguration(mode: .require),
            signsInWithToken: true
        )
    }
}

import Foundation
import TableProPluginKit
import Testing

struct ClickHouseConnectFailureTests {
    private func message(of error: Error) -> String? {
        (error as? ClickHouseError)?.message
    }

    @Test("A wrong password shows the server's own explanation")
    func authenticationFailureKeepsServerText() {
        let serverText = "Code: 516. DB::Exception: default: Authentication failed: password is incorrect, "
            + "or there is no user with such name. (AUTHENTICATION_FAILED)"

        let mapped = ClickHouseConnectFailure.error(for: ClickHouseError(message: serverText), tlsRefusal: nil)

        #expect(message(of: mapped) == serverText)
    }

    @Test("An unknown database shows the server's own explanation")
    func unknownDatabaseKeepsServerText() {
        let serverText = "Code: 81. DB::Exception: Database analytics does not exist. (UNKNOWN_DATABASE)"

        let mapped = ClickHouseConnectFailure.error(for: ClickHouseError(message: serverText), tlsRefusal: nil)

        #expect(message(of: mapped) == serverText)
    }

    @Test("A refused host says what the network said, not only that the connection failed")
    func transportFailureNamesTheCause() throws {
        let transport = URLError(.cannotConnectToHost)

        let text = try #require(message(of: ClickHouseConnectFailure.error(for: transport, tlsRefusal: nil)))

        #expect(text.contains(transport.localizedDescription))
    }

    @Test("A certificate the TLS delegate refused is reported as that refusal")
    func recordedRefusalWins() {
        let refusal = SSLHandshakeError.hostnameMismatch(serverMessage: "host name mismatch")

        let mapped = ClickHouseConnectFailure.error(for: URLError(.cancelled), tlsRefusal: refusal)

        guard case .hostnameMismatch = mapped as? SSLHandshakeError else {
            Issue.record("Expected the recorded hostname mismatch, got \(mapped)")
            return
        }
    }

    @Test("An untrusted server certificate is still reported as a TLS failure")
    func untrustedCertificateIsTLS() {
        let mapped = ClickHouseConnectFailure.error(for: URLError(.serverCertificateUntrusted), tlsRefusal: nil)

        guard case .untrustedCertificate = mapped as? SSLHandshakeError else {
            Issue.record("Expected an untrusted certificate, got \(mapped)")
            return
        }
    }

    @Test("An error status with no body names the status instead of an empty message")
    func emptyErrorBodyNamesTheStatus() async throws {
        let server = ClickHouseStubServer { _ in ClickHouseStubReply(statusCode: 502, body: "") }
        let driver = server.connectedDriver()

        let error = await #expect(throws: ClickHouseError.self) {
            try await driver.execute(query: "SELECT 1")
        }

        let mapped = try #require(error.map { ClickHouseConnectFailure.error(for: $0, tlsRefusal: nil) })
        #expect(message(of: mapped)?.contains("502") == true)
    }

    @Test("A streamed read answered with an error status and no body names the status")
    func emptyStreamedErrorBodyNamesTheStatus() async throws {
        let server = ClickHouseStubServer { _ in ClickHouseStubReply(statusCode: 503, body: "  \n") }
        let driver = server.connectedDriver()

        let error = await #expect(throws: ClickHouseError.self) {
            _ = try await driver.executeBoundedQuery(query: "SELECT 1", rowCap: 10)
        }

        #expect(error?.message.contains("503") == true)
    }
}

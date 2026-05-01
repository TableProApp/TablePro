import Foundation
@testable import TablePro
import Testing

@Suite("MCP HTTP Server Configuration")
struct MCPHttpServerConfigurationTests {
    @Test("Loopback factory works without TLS")
    func loopbackWithoutTls() {
        let config = MCPHttpServerConfiguration.loopback(port: 23_508)
        #expect(config.bindAddress == .loopback)
        #expect(config.port == 23_508)
        #expect(config.tls == nil)
        #expect(config.limits.maxRequestBodyBytes == 10 * 1_024 * 1_024)
    }

    @Test("Standard limits expose 10 MiB body cap and 16 KiB header cap")
    func standardLimits() {
        let limits = MCPHttpServerLimits.standard
        #expect(limits.maxRequestBodyBytes == 10 * 1_024 * 1_024)
        #expect(limits.maxHeaderBytes == 16 * 1_024)
        #expect(limits.connectionTimeout == .seconds(30))
    }

    @Test("Custom limits are preserved")
    func customLimits() {
        let limits = MCPHttpServerLimits(
            maxRequestBodyBytes: 1_024,
            maxHeaderBytes: 512,
            connectionTimeout: .seconds(5)
        )
        let config = MCPHttpServerConfiguration.loopback(port: 5_000, limits: limits)
        #expect(config.limits.maxRequestBodyBytes == 1_024)
        #expect(config.limits.maxHeaderBytes == 512)
        #expect(config.limits.connectionTimeout == .seconds(5))
    }

    @Test("Loopback factory custom port is preserved")
    func customPort() {
        let config = MCPHttpServerConfiguration.loopback(port: 65_500)
        #expect(config.port == 65_500)
    }

    @Test("Transport refuses to start anyInterface bind without TLS")
    func remoteRequiresTls() async {
        let store = MCPSessionStore()
        let authenticator = StubAlwaysAllowAuthenticator()
        let unsafe = MCPHttpServerConfiguration.unsafeMake(
            bindAddress: .anyInterface,
            port: 0,
            tls: nil,
            limits: .standard
        )
        let transport = MCPHttpServerTransport(
            configuration: unsafe,
            sessionStore: store,
            authenticator: authenticator
        )
        var captured: Error?
        do {
            try await transport.start()
        } catch {
            captured = error
        }
        #expect(captured is MCPHttpServerError)
        if case .tlsRequiredForRemoteAccess = captured as? MCPHttpServerError {
            #expect(true)
        } else {
            Issue.record("Expected tlsRequiredForRemoteAccess, got \(String(describing: captured))")
        }
        await transport.stop()
    }
}

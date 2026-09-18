import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCP HTTP Server Configuration", .serialized)
struct MCPHttpServerConfigurationTests {
    @Test("The loopback factory carries the port and the standard limits")
    func loopbackFactory() {
        let config = MCPHttpServerConfiguration.loopback(port: 23_508)

        #expect(config.port == 23_508)
        #expect(config.limits == .standard)
    }

    @Test("Standard limits are a 10 MiB body cap, a 16 KiB header cap and a 30s idle timeout")
    func standardLimits() {
        let limits = MCPHttpServerLimits.standard

        #expect(limits.maxRequestBodyBytes == 10 * 1_024 * 1_024)
        #expect(limits.maxHeaderBytes == 16 * 1_024)
        #expect(limits.connectionTimeout == .seconds(30))
        #expect(limits.maxConcurrentConnections == 64)
    }

    @Test("An idle timeout is always set, so no connection can be pinned open forever")
    func idleTimeoutIsAlwaysPositive() {
        #expect(MCPHttpServerLimits.standard.connectionTimeout > .zero)

        let custom = MCPHttpServerLimits(
            maxRequestBodyBytes: 1_024,
            maxHeaderBytes: 512,
            connectionTimeout: .milliseconds(250)
        )
        #expect(custom.connectionTimeout > .zero)
    }

    @Test("Custom limits are preserved and reach the parser")
    func customLimitsReachTheParser() {
        let limits = MCPHttpServerLimits(
            maxRequestBodyBytes: 2_048,
            maxHeaderBytes: 512,
            connectionTimeout: .seconds(5),
            maxConcurrentConnections: 4
        )
        let config = MCPHttpServerConfiguration.loopback(port: 5_000, limits: limits)

        #expect(config.limits.maxRequestBodyBytes == 2_048)
        #expect(config.limits.maxHeaderBytes == 512)
        #expect(config.limits.connectionTimeout == .seconds(5))
        #expect(config.limits.maxConcurrentConnections == 4)
        #expect(config.limits.parserLimits == HttpParserLimits(maxHeaderBytes: 512, maxBodyBytes: 2_048))
    }

    @Test("The default connection ceiling applies when it is not named")
    func defaultConnectionCeiling() {
        let limits = MCPHttpServerLimits(
            maxRequestBodyBytes: 1_024,
            maxHeaderBytes: 512,
            connectionTimeout: .seconds(5)
        )

        #expect(limits.maxConcurrentConnections == 64)
    }

    @Test("Port 0 asks the system for a free port")
    func ephemeralPort() {
        #expect(MCPHttpServerConfiguration.loopback(port: 0).port == 0)
        #expect(MCPHttpServerConfiguration.loopback(port: 65_500).port == 65_500)
    }

    @Test("Configurations with the same port and limits are equal")
    func equality() {
        let left = MCPHttpServerConfiguration.loopback(port: 23_508)
        let right = MCPHttpServerConfiguration(port: 23_508, limits: .standard)
        let other = MCPHttpServerConfiguration.loopback(port: 23_509)

        #expect(left == right)
        #expect(left != other)
    }

    @Test("A second start on a running transport is refused")
    func doubleStartIsRefused() async throws {
        let (transport, port) = try await MCPTransportTestHarness.start()
        #expect(port != 0)

        var captured: MCPHttpServerError?
        do {
            try await transport.start()
        } catch let error as MCPHttpServerError {
            captured = error
        }
        await MCPTransportTestHarness.stop(transport)

        #expect(captured == .alreadyStarted)
    }

    @Test("A stopped transport reports the stopped state and no port")
    func stopClearsTheListeningPort() async throws {
        let (transport, _) = try await MCPTransportTestHarness.start()
        await MCPTransportTestHarness.stop(transport)

        #expect(await transport.state == .stopped)
        #expect(await transport.listeningPort == nil)
    }
}

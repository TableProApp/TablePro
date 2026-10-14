import Foundation
import Testing

@testable import TablePro

@MainActor
struct MCPServerOffContractTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-off-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func makeManager() -> MCPServerManager {
        MCPServerManager(handshake: MCPHandshakeFile(directory: directory), isEnabled: { false })
    }

    private var handshakeExists: Bool {
        FileManager.default.fileExists(atPath: MCPHandshakeLocation.file(in: directory).path)
    }

    private func readRefusal() throws -> MCPStartRefusal {
        let data = try Data(contentsOf: MCPHandshakeLocation.refusalFile(in: directory))
        return try MCPHandshakeCoding.decoder().decode(MCPStartRefusal.self, from: data)
    }

    private func expectNoListener(_ manager: MCPServerManager) {
        #expect(manager.state == .stopped)
        #expect(manager.tokenStore == nil)
        #expect(!handshakeExists)
    }

    @Test("A launch start is refused while MCP is off")
    func launchStartIsRefused() async throws {
        let manager = makeManager()

        await #expect(throws: MCPServerStartError.turnedOff) {
            try await manager.start(port: 0)
        }

        expectNoListener(manager)
        #expect(try readRefusal().pid == ProcessInfo.processInfo.processIdentifier)
    }

    @Test("A start-mcp request is refused while MCP is off")
    func lazyStartIsRefused() async throws {
        let manager = makeManager()

        await #expect(throws: MCPServerStartError.turnedOff) {
            try await manager.lazyStart()
        }

        expectNoListener(manager)
        _ = try readRefusal()
    }

    @Test("A restart from Settings is refused while MCP is off")
    func scheduledRestartIsRefused() async throws {
        let manager = makeManager()

        manager.scheduleRestart(port: 0)
        await manager.stop()

        expectNoListener(manager)
        _ = try readRefusal()
    }

    @Test("Pairing is refused before the approval prompt while MCP is off")
    func pairingIsRefused() async throws {
        let manager = makeManager()
        let service = MCPPairingService(serverManager: manager)
        let redirect = try #require(URL(string: "http://127.0.0.1:7391/callback"))
        let request = PairingRequest(
            clientName: "Launcher",
            challenge: PairingExchangeStore.sha256Base64Url(
                of: String(repeating: "a", count: PairingPkceValidator.minimumVerifierLength)
            ),
            redirectURL: redirect,
            requestedScopes: nil,
            requestedConnectionIds: nil
        )

        await #expect(throws: MCPServerStartError.turnedOff) {
            try await service.startPairing(request)
        }

        expectNoListener(manager)
    }

    @Test("The refusal message names Settings > MCP")
    func refusalNamesTheSetting() {
        #expect(MCPServerStartError.turnedOff.localizedDescription.contains("Settings > MCP"))
    }
}

struct MCPBridgeRefusalTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    @Test("The bridge gives up at once when the app refuses its launch")
    func bridgeFailsOnARefusal() async throws {
        let directory = directory
        let acquirer = MCPHandshakeAcquirer(
            logger: SilentBridgeLogger(),
            supportDirectory: directory,
            pollTimeout: .seconds(30),
            launchHostApp: { _ in try Self.writeRefusal(at: Date(), in: directory) }
        )

        let started = ContinuousClock().now
        await #expect(throws: MCPHandshakeAcquisitionError.serverTurnedOff) {
            _ = try await acquirer.acquire()
        }
        #expect(ContinuousClock().now - started < .seconds(5))
        #expect(MCPHandshakeAcquisitionError.serverTurnedOff.localizedDescription.contains("Settings > MCP"))
    }

    @Test("A refusal from before the launch does not answer it")
    func staleRefusalIsIgnored() async throws {
        try Self.writeRefusal(at: Date().addingTimeInterval(-60), in: directory)
        let acquirer = MCPHandshakeAcquirer(
            logger: SilentBridgeLogger(),
            supportDirectory: directory,
            pollTimeout: .milliseconds(300),
            launchHostApp: { _ in }
        )

        do {
            _ = try await acquirer.acquire()
            Issue.record("Expected the bridge to time out")
        } catch let error as MCPHandshakeAcquisitionError {
            guard case .timeout = error else {
                Issue.record("Expected a timeout, got \(error)")
                return
            }
        }
    }

    @Test("A refusal answers only a launch requested before it, to the sub-second")
    func refusalAnswersLaterLaunchesOnly() throws {
        let launch = Date(timeIntervalSince1970: 1_000.9)
        #expect(MCPStartRefusal(pid: 1, refusedAt: launch.addingTimeInterval(0.05)).answers(launchRequestedAt: launch))
        #expect(MCPStartRefusal(pid: 1, refusedAt: launch.addingTimeInterval(5)).answers(launchRequestedAt: launch))
        #expect(!MCPStartRefusal(pid: 1, refusedAt: launch.addingTimeInterval(-5)).answers(launchRequestedAt: launch))

        let earlierInTheSameSecond = MCPStartRefusal(pid: 1, refusedAt: Date(timeIntervalSince1970: 1_000.1))
        let decoded = try MCPHandshakeCoding.decoder().decode(
            MCPStartRefusal.self,
            from: MCPHandshakeCoding.encoder().encode(earlierInTheSameSecond)
        )
        #expect(!decoded.answers(launchRequestedAt: launch))
    }

    private static func writeRefusal(at date: Date, in directory: URL) throws {
        let data = try MCPHandshakeCoding.encoder().encode(MCPStartRefusal(pid: 1, refusedAt: date))
        try data.write(to: MCPHandshakeLocation.refusalFile(in: directory))
    }
}

private struct SilentBridgeLogger: MCPBridgeLogger {
    func log(_ level: MCPBridgeLogLevel, _ message: String) {}
}

@MainActor
struct MCPServerLifecycleQueueResultTests {
    @Test("run hands back what its work returned, after the work queued before it")
    func runReturnsTheValueInOrder() async {
        let queue = MCPServerLifecycleQueue()
        let log = OrderLog()

        queue.enqueue {
            try? await Task.sleep(for: .milliseconds(20))
            log.entries.append("earlier")
        }
        let value = await queue.run { () async -> String in
            log.entries.append("run")
            return "result"
        }

        #expect(value == "result")
        #expect(log.entries == ["earlier", "run"])
    }
}

@MainActor
private final class OrderLog {
    var entries: [String] = []
}

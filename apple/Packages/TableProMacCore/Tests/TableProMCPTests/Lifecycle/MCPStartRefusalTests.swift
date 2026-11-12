import Foundation
@testable import TableProMCP
import Testing

struct MCPStartRefusalTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-refusal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    @Test("A refusal written before refusals carried a reason reads as turned off")
    func refusalWithoutAReasonIsTurnedOff() throws {
        let refusal = try MCPHandshakeCoding.decoder().decode(
            MCPStartRefusal.self,
            from: Data(#"{"pid":1,"refusedAt":1000.5}"#.utf8)
        )

        #expect(refusal.reason == .turnedOff)
    }

    @Test("A reason this build does not know still says the server is not coming up")
    func unknownReasonIsAFailedStart() throws {
        let refusal = try MCPHandshakeCoding.decoder().decode(
            MCPStartRefusal.self,
            from: Data(#"{"pid":1,"refusedAt":1000.5,"reason":"somethingNewer"}"#.utf8)
        )

        #expect(refusal.reason == .failedToStart)
    }

    @Test("A failed start keeps its reason through the file")
    func failedStartRoundTrips() throws {
        let written = MCPStartRefusal(pid: 7, refusedAt: Date(timeIntervalSince1970: 1_000.25), reason: .failedToStart)

        let read = try MCPHandshakeCoding.decoder().decode(
            MCPStartRefusal.self,
            from: MCPHandshakeCoding.encoder().encode(written)
        )

        #expect(read == written)
    }

    @Test("The bridge names a failed start instead of waiting out the timeout")
    func bridgeReportsAFailedStart() async throws {
        let directory = directory
        let acquirer = MCPHandshakeAcquirer(
            logger: SilentLogger(),
            supportDirectory: directory,
            pollTimeout: .seconds(30),
            launchHostApp: { _ in
                let refusal = MCPStartRefusal(pid: 1, refusedAt: Date(), reason: .failedToStart)
                try MCPHandshakeCoding.encoder().encode(refusal).write(to: MCPHandshakeLocation.refusalFile(in: directory))
            }
        )

        let started = ContinuousClock().now
        await #expect(throws: MCPHandshakeAcquisitionError.serverFailedToStart) {
            _ = try await acquirer.acquire()
        }
        #expect(ContinuousClock().now - started < .seconds(5))
        let message = MCPHandshakeAcquisitionError.serverFailedToStart.localizedDescription
        #expect(message.contains("Settings > MCP"))
        #expect(!message.contains("not running"))
    }
}

private struct SilentLogger: MCPBridgeLogger {
    func log(_ level: MCPBridgeLogLevel, _ message: String) {}
}

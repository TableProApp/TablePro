// A file or URL open builds its connection in the router, so its failure must not be alerted over the window showing it.

import Foundation
@testable import TablePro
import TableProMCP
import Testing

@MainActor
struct LaunchIntentFailureOwnershipTests {
    private static let underlying = PluginError.pluginLoadFailed(pluginId: "com.TablePro.SQLiteDriver", pluginName: "SQLite", reason: nil)

    @Test("A file open whose connect failed in its window names that window's connection")
    func fileOpenFailureNamesItsConnection() {
        let connectionId = UUID()
        let error = TabRouterError.connectFailedInWindow(connectionId: connectionId, underlying: Self.underlying)
        let intent = LaunchIntent.openDatabaseFile(URL(fileURLWithPath: "/tmp/empty.sqlite"), .sqlite)

        #expect(LaunchIntentRouter.failedConnectionId(for: intent, error: error) == connectionId)
    }

    @Test("A file open that failed before any window opened names no connection")
    func preWindowFailureNamesNone() {
        let url = URL(fileURLWithPath: "/tmp/gone.sqlite")
        let intent = LaunchIntent.openDatabaseFile(url, .sqlite)

        #expect(LaunchIntentRouter.failedConnectionId(for: intent, error: TabRouterError.fileNoLongerExists(url)) == nil)
    }

    @Test("An intent that names its connection keeps naming it")
    func connectionIntentNamesItsConnection() {
        let connectionId = UUID()

        #expect(LaunchIntentRouter.failedConnectionId(for: .openConnection(connectionId), error: Self.underlying) == connectionId)
    }

    @Test("A failure handed to a window still reads as the driver's own message")
    func windowFailureKeepsTheUnderlyingMessage() {
        let error = TabRouterError.connectFailedInWindow(connectionId: UUID(), underlying: Self.underlying)

        #expect(error.localizedDescription == Self.underlying.localizedDescription)
    }

    @Test("A background launch made only for MCP quits when the server fails to start, as it does when MCP is off")
    func failedMCPStartEndsAnIdleLaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-launch-\(UUID().uuidString)", isDirectory: true)
        // Too long for a socket path, so the server falls back to the temporary folder, which is a file here.
        let directory = root.appendingPathComponent(String(repeating: "d", count: 110), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notAFolder = root.appendingPathComponent("tmp-file", isDirectory: false)
        try Data().write(to: notAFolder)
        let manager = MCPServerManager(
            handshake: MCPHandshakeFile(directory: directory, temporaryDirectory: notAFolder),
            isEnabled: { true }
        )

        #expect(await LaunchIntentRouter.startMCPServerLeavesNothingToDo(manager: manager, isIdleMachineSession: { true }))
        #expect(manager.state == .failed(.socketFolderUnusable))
        #expect(!(await LaunchIntentRouter.startMCPServerLeavesNothingToDo(manager: manager, isIdleMachineSession: { false })))
        await manager.stop()
    }

    @Test("A background launch made only for MCP quits when MCP is off")
    func refusedMCPStartEndsAnIdleLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-launch-off-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = MCPServerManager(handshake: MCPHandshakeFile(directory: directory), isEnabled: { false })

        #expect(await LaunchIntentRouter.startMCPServerLeavesNothingToDo(manager: manager, isIdleMachineSession: { true }))
        #expect(manager.state == .stopped)
    }
}

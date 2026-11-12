import Combine
import Foundation
import Testing

@testable import TablePro
import TableProMCP

@MainActor
struct MCPServerClientListTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-clients-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    @Test("A client list refresh that finds nothing new publishes nothing")
    func unchangedRefreshPublishesNothing() async {
        let manager = MCPServerManager(handshake: MCPHandshakeFile(directory: directory), isEnabled: { false })
        var published = 0
        let subscription = manager.objectWillChange.sink { _ in published += 1 }
        defer { subscription.cancel() }

        await manager.refreshClients()
        await manager.refreshClients()

        #expect(published == 0)
        #expect(manager.connectedClients.isEmpty)
    }

    @Test("The client list refresh ends with the task of the view that shows it")
    func refreshEndsWithItsTask() async {
        let manager = MCPServerManager(handshake: MCPHandshakeFile(directory: directory), isEnabled: { false })
        let shown = Task { await manager.refreshClientsWhileShown() }
        shown.cancel()
        await shown.value
        #expect(manager.connectedClients.isEmpty)
    }
}

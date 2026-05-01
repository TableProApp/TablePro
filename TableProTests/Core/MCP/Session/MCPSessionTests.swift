import Foundation
@testable import TablePro
import Testing

@Suite("MCP Session")
struct MCPSessionTests {
    @Test("New session starts in initializing state")
    func newSessionStartsInitializing() async {
        let session = MCPSession()
        let state = await session.state
        #expect(state == .initializing)
    }

    @Test("Transition initializing to ready succeeds")
    func transitionInitializingToReady() async throws {
        let session = MCPSession()
        try await session.transitionToReady()
        let state = await session.state
        #expect(state == .ready)
    }

    @Test("Cannot transition to ready twice")
    func cannotTransitionToReadyTwice() async throws {
        let session = MCPSession()
        try await session.transitionToReady()
        await #expect(throws: MCPSessionTransitionError.self) {
            try await session.transitionToReady()
        }
    }

    @Test("Cannot transition to ready after termination")
    func cannotTransitionAfterTermination() async {
        let session = MCPSession()
        await session.terminate(reason: .clientRequested)
        await #expect(throws: MCPSessionTransitionError.self) {
            try await session.transitionToReady()
        }
    }

    @Test("Touch updates last activity for non-terminated sessions")
    func touchUpdatesLastActivity() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let session = MCPSession(now: start)
        let later = start.addingTimeInterval(30)
        await session.touch(now: later)
        let activity = await session.lastActivityAt
        #expect(activity == later)
    }

    @Test("Touch is ignored after termination")
    func touchIgnoredAfterTermination() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let session = MCPSession(now: start)
        await session.terminate(reason: .idleTimeout)
        let later = start.addingTimeInterval(60)
        await session.touch(now: later)
        let activity = await session.lastActivityAt
        #expect(activity == start)
    }

    @Test("recordInitialize stores client info and capabilities")
    func recordInitializeStoresInfo() async {
        let session = MCPSession()
        let info = MCPClientInfo(name: "Claude", version: "1.0")
        await session.recordInitialize(
            clientInfo: info,
            protocolVersion: "2024-11-05",
            capabilities: .object(["sampling": .object([:])])
        )
        let stored = await session.clientInfo
        let version = await session.negotiatedProtocolVersion
        #expect(stored == info)
        #expect(version == "2024-11-05")
    }

    @Test("Snapshot reflects current state")
    func snapshotReflectsState() async throws {
        let session = MCPSession()
        try await session.transitionToReady()
        let info = MCPClientInfo(name: "TestClient", version: nil)
        await session.recordInitialize(clientInfo: info, protocolVersion: "v1", capabilities: nil)
        let snapshot = await session.snapshot()
        #expect(snapshot.state == .ready)
        #expect(snapshot.clientInfo == info)
    }

    @Test("Termination is idempotent")
    func terminationIsIdempotent() async {
        let session = MCPSession()
        await session.terminate(reason: .clientRequested)
        await session.terminate(reason: .idleTimeout)
        let state = await session.state
        #expect(state == .terminated(reason: .clientRequested))
    }
}

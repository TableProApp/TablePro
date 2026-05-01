import Foundation
@testable import TablePro
import Testing

@Suite("MCP Session Store")
struct MCPSessionStoreTests {
    @Test("Create then lookup returns same session")
    func createThenLookup() async throws {
        let store = MCPSessionStore()
        let session = try await store.create()
        let found = await store.session(id: session.id)
        #expect(found != nil)
        let count = await store.count()
        #expect(count == 1)
    }

    @Test("Touch updates session lastActivity to current clock time")
    func touchUpdatesLastActivity() async throws {
        let clock = MCPTestClock(start: Date(timeIntervalSince1970: 1_000_000))
        let store = MCPSessionStore(clock: clock)
        let session = try await store.create()

        await clock.advance(by: .seconds(120))
        await store.touch(id: session.id)

        let activity = await session.lastActivityAt
        let expected = Date(timeIntervalSince1970: 1_000_000 + 120)
        #expect(activity == expected)
    }

    @Test("Capacity overflow throws")
    func capacityOverflow() async throws {
        let policy = MCPSessionPolicy(
            idleTimeout: .seconds(900),
            maxSessions: 2,
            cleanupInterval: .seconds(60)
        )
        let store = MCPSessionStore(policy: policy)
        _ = try await store.create()
        _ = try await store.create()
        await #expect(throws: MCPSessionStoreError.self) {
            _ = try await store.create()
        }
    }

    @Test("Idle eviction terminates expired sessions")
    func idleEviction() async throws {
        let clock = MCPTestClock(start: Date(timeIntervalSince1970: 1_000_000))
        let policy = MCPSessionPolicy(
            idleTimeout: .seconds(300),
            maxSessions: 16,
            cleanupInterval: .seconds(60)
        )
        let store = MCPSessionStore(policy: policy, clock: clock)
        let active = try await store.create()
        let stale = try await store.create()

        await clock.advance(by: .seconds(200))
        await store.touch(id: active.id)

        await clock.advance(by: .seconds(200))
        await store.runCleanupPass()

        let activeFound = await store.session(id: active.id)
        let staleFound = await store.session(id: stale.id)
        #expect(activeFound != nil)
        #expect(staleFound == nil)
    }

    @Test("Termination broadcasts to subscribers")
    func terminationBroadcastsEvents() async throws {
        let store = MCPSessionStore()
        let stream = await store.events

        let session = try await store.create()
        await store.terminate(id: session.id, reason: .clientRequested)

        var collected: [MCPSessionEvent] = []
        var iterator = stream.makeAsyncIterator()
        if let event = await iterator.next() {
            collected.append(event)
        }
        if let event = await iterator.next() {
            collected.append(event)
        }

        #expect(collected.count == 2)
        guard case .created(let createdId) = collected[0] else {
            Issue.record("Expected created event, got \(collected[0])")
            return
        }
        guard case .terminated(let terminatedId, let reason) = collected[1] else {
            Issue.record("Expected terminated event, got \(collected[1])")
            return
        }
        #expect(createdId == session.id)
        #expect(terminatedId == session.id)
        #expect(reason == .clientRequested)
    }

    @Test("Multiple subscribers receive same events")
    func multipleSubscribersReceiveSameEvents() async throws {
        let store = MCPSessionStore()
        let streamA = await store.events
        let streamB = await store.events

        let session = try await store.create()
        await store.terminate(id: session.id, reason: .idleTimeout)

        var iteratorA = streamA.makeAsyncIterator()
        var iteratorB = streamB.makeAsyncIterator()

        let firstA = await iteratorA.next()
        let firstB = await iteratorB.next()
        #expect(firstA != nil)
        #expect(firstB != nil)

        let secondA = await iteratorA.next()
        let secondB = await iteratorB.next()
        guard case .terminated(_, let reasonA) = secondA else {
            Issue.record("Expected terminated for A")
            return
        }
        guard case .terminated(_, let reasonB) = secondB else {
            Issue.record("Expected terminated for B")
            return
        }
        #expect(reasonA == .idleTimeout)
        #expect(reasonB == .idleTimeout)
    }

    @Test("Terminate on missing id is a no-op")
    func terminateMissingIsNoop() async {
        let store = MCPSessionStore()
        let unknown = MCPSessionId.generate()
        await store.terminate(id: unknown, reason: .clientRequested)
        let count = await store.count()
        #expect(count == 0)
    }

    @Test("Cleanup pass with no idle sessions does nothing")
    func cleanupNoIdle() async throws {
        let clock = MCPTestClock()
        let policy = MCPSessionPolicy(
            idleTimeout: .seconds(900),
            maxSessions: 8,
            cleanupInterval: .seconds(60)
        )
        let store = MCPSessionStore(policy: policy, clock: clock)
        let session = try await store.create()
        await clock.advance(by: .seconds(60))
        await store.runCleanupPass()
        let found = await store.session(id: session.id)
        #expect(found != nil)
    }

    @Test("Idle eviction emits idleTimeout event")
    func idleEvictionEmitsTimeoutEvent() async throws {
        let clock = MCPTestClock(start: Date(timeIntervalSince1970: 2_000_000))
        let policy = MCPSessionPolicy(
            idleTimeout: .seconds(60),
            maxSessions: 4,
            cleanupInterval: .seconds(15)
        )
        let store = MCPSessionStore(policy: policy, clock: clock)
        let stream = await store.events
        let session = try await store.create()

        await clock.advance(by: .seconds(120))
        await store.runCleanupPass()

        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let terminationEvent = await iterator.next()
        guard case .terminated(let id, let reason) = terminationEvent else {
            Issue.record("Expected terminated event, got \(String(describing: terminationEvent))")
            return
        }
        #expect(id == session.id)
        #expect(reason == .idleTimeout)
    }
}

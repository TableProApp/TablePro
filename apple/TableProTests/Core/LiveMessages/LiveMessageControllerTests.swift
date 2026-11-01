import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private final class FakeSubscription: PluginLiveSubscription, @unchecked Sendable {
    let messages: AsyncThrowingStream<PluginLiveMessage, Error>
    let continuation: AsyncThrowingStream<PluginLiveMessage, Error>.Continuation
    private let lock = NSLock()
    private var _published: [String] = []
    private var _isClosed = false

    init() {
        (messages, continuation) = AsyncThrowingStream<PluginLiveMessage, Error>.makeStream()
    }

    var published: [String] { lock.withLock { _published } }
    var isClosed: Bool { lock.withLock { _isClosed } }

    func publish(_ payload: String, to channel: String) async throws {
        lock.withLock { _published.append("\(channel):\(payload)") }
    }

    func close() async {
        lock.withLock { _isClosed = true }
        continuation.finish()
    }
}

private struct Dropped: Error, LocalizedError {
    var errorDescription: String? { "server closed the connection" }
}

@MainActor
private final class Harness {
    var subscriptions: [FakeSubscription] = []
    var failFirst = false
    var opened = 0
    var closedSources = 0
    let clock = ManualClock()
    private(set) var controller: LiveMessageController!

    init(capacity: Int = LiveMessageBuffer.defaultCapacity) {
        controller = LiveMessageController(
            kind: .notifications,
            request: PluginLiveSubscriptionRequest(channels: ["orders"]),
            capacity: capacity,
            clock: clock,
            makeSource: { LiveMessageSessionSource { throw LiveMessageError.unsupported } },
            subscribe: { [weak self] _ in try await self!.next() }
        )
    }

    func next() async throws -> any PluginLiveSubscription {
        opened += 1
        if failFirst { throw Dropped() }
        let subscription = FakeSubscription()
        subscriptions.append(subscription)
        return subscription
    }

    static func message(_ payload: String) -> PluginLiveMessage {
        PluginLiveMessage(timestamp: Date(), channel: "orders", payload: payload)
    }
}

@MainActor
struct LiveMessageControllerTests {
    @Test("Messages that arrive while paused are kept and shown on resume")
    func pauseLosesNothing() async throws {
        let harness = Harness()
        let controller = harness.controller!
        controller.start()
        try await waitUntil { controller.phase == .live }

        controller.pause()
        harness.subscriptions[0].continuation.yield(Harness.message("one"))
        harness.subscriptions[0].continuation.yield(Harness.message("two"))
        try await waitUntil { controller.unseenCount == 2 }
        #expect(controller.shown.isEmpty)

        controller.resume()
        #expect(controller.shown.compactMap { $0.message?.payload } == ["one", "two"])
        #expect(controller.unseenCount == 0)
        controller.stop()
    }

    @Test("A dropped connection leaves one gap row and subscribes again after the backoff")
    func dropReconnects() async throws {
        let harness = Harness()
        let controller = harness.controller!
        controller.start()
        try await waitUntil { controller.phase == .live }

        harness.subscriptions[0].continuation.finish(throwing: Dropped())
        try await waitUntil { controller.phase == .reconnecting("server closed the connection") }
        #expect(harness.subscriptions[0].isClosed)
        #expect(controller.buffer.entries.count == 1)
        #expect(controller.buffer.entries.first?.message == nil)

        // The table refresh and the backoff both sleep on the clock.
        try await waitUntil { harness.clock.pendingSleeperCount == 2 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.opened == 2 && controller.phase == .live }
        controller.stop()
    }

    @Test("A first subscribe that fails ends the tab with the error instead of retrying")
    func firstFailureEnds() async throws {
        let harness = Harness()
        harness.failFirst = true
        let controller = harness.controller!
        controller.start()

        try await waitUntil { controller.hasEnded }
        #expect(controller.phase == .ended("server closed the connection"))
        #expect(harness.opened == 1)
    }

    @Test("Stopping closes the subscription and refuses a publish")
    func stopCloses() async throws {
        let harness = Harness()
        let controller = harness.controller!
        controller.start()
        try await waitUntil { controller.phase == .live }

        try await controller.publish("hi", to: "orders")
        #expect(harness.subscriptions[0].published == ["orders:hi"])

        controller.stop()
        try await waitUntil { harness.subscriptions[0].isClosed }
        await #expect(throws: LiveMessageError.ended) {
            try await controller.publish("late", to: "orders")
        }
    }

    @Test("Closing a live tab's tab id stops its controller")
    func sessionsEndStopsController() async throws {
        let harness = Harness()
        let controller = harness.controller!
        let sessions = LiveMessageSessions()
        let tabId = UUID()
        sessions.register(controller, tabId: tabId, connectionId: UUID())
        controller.start()
        try await waitUntil { controller.phase == .live }

        sessions.end(tabId: tabId)
        #expect(controller.hasEnded)
        #expect(sessions.controller(forTab: tabId) == nil)
        try await waitUntil { harness.subscriptions[0].isClosed }
    }
}

@MainActor
struct LiveMessageSessionsTests {
    @Test("Disconnecting a connection stops only that connection's live tabs")
    func endByConnection() async throws {
        let first = Harness()
        let second = Harness()
        let sessions = LiveMessageSessions()
        let connection = UUID()
        sessions.register(first.controller, tabId: UUID(), connectionId: connection)
        sessions.register(second.controller, tabId: UUID(), connectionId: UUID())
        first.controller.start()
        second.controller.start()
        try await waitUntil { first.controller.phase == .live && second.controller.phase == .live }

        sessions.end(connectionId: connection)
        #expect(first.controller.hasEnded)
        #expect(!second.controller.hasEnded)
        second.controller.stop()
    }
}

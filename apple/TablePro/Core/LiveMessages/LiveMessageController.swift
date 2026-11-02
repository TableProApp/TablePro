//
//  LiveMessageController.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

// One live tab: a subscription on connections of its own, re-opened after a drop, and the messages it kept.
@MainActor
internal final class LiveMessageController: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case live
        case reconnecting(String)
        case ended(String?)
    }

    typealias Subscribe = @Sendable (LiveMessageSessionSource) async throws -> any PluginLiveSubscription

    static let refreshInterval: Duration = .milliseconds(100)
    static let maximumBackoff: Duration = .seconds(30)
    private static let logger = Logger(subsystem: "com.TablePro", category: "LiveMessages")

    let kind: PluginLiveMessageKind
    let request: PluginLiveSubscriptionRequest

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var shown: [LiveMessageEntry] = []
    @Published private(set) var isPaused = false
    // Kept while paused and not yet shown.
    @Published private(set) var unseenCount = 0
    @Published var filter = "" {
        didSet { refreshShown() }
    }

    private(set) var buffer: LiveMessageBuffer
    // What the table showed when it was paused; the buffer keeps growing underneath.
    private var frozen: [LiveMessageEntry] = []
    private let subscribe: Subscribe
    private let makeSource: @MainActor () -> LiveMessageSessionSource
    private let clock: any Clock<Duration>
    private var runTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var subscription: (any PluginLiveSubscription)?
    private var source: LiveMessageSessionSource?

    init(
        kind: PluginLiveMessageKind,
        request: PluginLiveSubscriptionRequest,
        capacity: Int = LiveMessageBuffer.defaultCapacity,
        clock: any Clock<Duration> = ContinuousClock(),
        makeSource: @escaping @MainActor () -> LiveMessageSessionSource,
        subscribe: @escaping Subscribe
    ) {
        self.kind = kind
        self.request = request
        self.buffer = LiveMessageBuffer(capacity: capacity)
        self.clock = clock
        self.makeSource = makeSource
        self.subscribe = subscribe
    }

    static func title(for request: PluginLiveSubscriptionRequest) -> String {
        let names = (request.channels + request.patterns).joined(separator: ", ")
        return String(format: String(localized: "Live: %@"), names)
    }

        var hasEnded: Bool {
        if case .ended = phase { return true }
        return false
    }

    var canPublish: Bool { phase == .live }

    // MARK: - Lifecycle

    func start() {
        guard runTask == nil, !hasEnded else { return }
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    // Ends the subscription and closes every connection it opened; the messages stay on screen.
    func stop() {
        guard !hasEnded else { return }
        phase = .ended(nil)
        runTask?.cancel()
        runTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshShown()
        let subscription = subscription
        let source = source
        self.subscription = nil
        self.source = nil
        Task {
            await subscription?.close()
            await source?.closeAll()
        }
    }

    private func run() async {
        var hasSubscribed = false
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            let source = makeSource()
            self.source = source
            do {
                let opened = try await subscribe(source)
                guard !Task.isCancelled else {
                    await opened.close()
                    await source.closeAll()
                    return
                }
                subscription = opened
                phase = .live
                hasSubscribed = true
                backoff = .seconds(1)
                for try await message in opened.messages {
                    receive(message)
                }
                guard !Task.isCancelled else { return }
                await dropped(subscription: opened, source: source, reason: String(localized: "The connection closed."))
            } catch {
                guard !Task.isCancelled else { return }
                // A first subscribe that fails is a wrong channel, topic or permission: retrying would only repeat it.
                guard hasSubscribed else {
                    await source.closeAll()
                    self.source = nil
                    phase = .ended(error.localizedDescription)
                    return
                }
                await dropped(subscription: subscription, source: source, reason: error.localizedDescription)
            }
            do {
                try await clock.sleep(for: backoff)
            } catch {
                return
            }
            backoff = min(backoff * 2, Self.maximumBackoff)
        }
    }

    private func dropped(subscription dropped: (any PluginLiveSubscription)?, source: LiveMessageSessionSource, reason: String) async {
        Self.logger.info("Live subscription dropped: \(reason, privacy: .private)")
        if case .reconnecting = phase {} else {
            buffer.appendGap(reason: reason)
            scheduleRefresh()
        }
        phase = .reconnecting(reason)
        subscription = nil
        self.source = nil
        await dropped?.close()
        await source.closeAll()
    }

    // MARK: - Messages

    func receive(_ message: PluginLiveMessage) {
        buffer.append([message])
        if isPaused {
            unseenCount += 1
        } else {
            scheduleRefresh()
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        refreshTask?.cancel()
        refreshTask = nil
        frozen = buffer.entries
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        unseenCount = 0
        frozen = []
        refreshShown()
    }

    func clear() {
        buffer.clear()
        frozen = []
        unseenCount = 0
        refreshShown()
    }

    func publish(_ payload: String, to channel: String) async throws {
        guard let subscription, phase == .live else { throw LiveMessageError.ended }
        try await subscription.publish(payload, to: channel)
    }

    // Coalesced, so a burst of messages redraws the table once per interval rather than once per message.
    private func scheduleRefresh() {
        guard refreshTask == nil, !isPaused else { return }
        let clock = clock
        refreshTask = Task { [weak self] in
            try? await clock.sleep(for: Self.refreshInterval)
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.refreshShown()
        }
    }

    private func refreshShown() {
        shown = LiveMessageBuffer.filter(isPaused ? frozen : buffer.entries, by: filter)
    }
}

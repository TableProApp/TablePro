//
//  KeyWindowCommandSubscriptionTests.swift
//  TableProTests
//

import AppKit
import Combine
import Foundation
import Testing

@testable import TablePro

@MainActor
struct KeyWindowCommandSubscriptionTests {
    private final class Received {
        var payloads: [Int] = []
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Only the subscriber whose window is frontmost runs the command")
    func onlyTheFrontmostSubscriberRuns() async throws {
        let subject = PassthroughSubject<Int, Never>()
        let background = Received()
        let frontmost = Received()
        let backgroundSubscription = KeyWindowCommandSubscription.sink(subject, when: { false }) {
            background.payloads.append($0)
        }
        let frontmostSubscription = KeyWindowCommandSubscription.sink(subject, when: { true }) {
            frontmost.payloads.append($0)
        }

        subject.send(7)
        try await waitUntil { !frontmost.payloads.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(frontmost.payloads == [7])
        #expect(background.payloads.isEmpty)
        backgroundSubscription.cancel()
        frontmostSubscription.cancel()
    }

    @Test("A window that is not key does not run the command")
    func windowThatIsNotKeyDoesNotRun() async throws {
        let subject = PassthroughSubject<Void, Never>()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let received = Received()
        let subscription = KeyWindowCommandSubscription.sink(subject, whileKey: { window }) { _ in
            received.payloads.append(1)
        }

        subject.send(())
        try await Task.sleep(for: .milliseconds(100))

        #expect(!window.isKeyWindow)
        #expect(received.payloads.isEmpty)
        subscription.cancel()
    }
}

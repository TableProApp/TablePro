import AppKit
import Combine
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct KeyWindowCommandSubscriptionTests {
    private final class Received {
        var payloads: [Int] = []
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
        // Deliveries run on the main run loop in subscription order, so the background
        // subscriber's has run by the time the frontmost one's lands.
        try await waitUntil { !frontmost.payloads.isEmpty }

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
        // Subscribed after, so its delivery on the main run loop comes after the window's.
        let control = Received()
        let controlSubscription = KeyWindowCommandSubscription.sink(subject, when: { true }) { _ in
            control.payloads.append(1)
        }

        subject.send(())
        try await waitUntil { !control.payloads.isEmpty }

        #expect(!window.isKeyWindow)
        #expect(received.payloads.isEmpty)
        subscription.cancel()
        controlSubscription.cancel()
    }
}

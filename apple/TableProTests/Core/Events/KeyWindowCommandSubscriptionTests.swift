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
}

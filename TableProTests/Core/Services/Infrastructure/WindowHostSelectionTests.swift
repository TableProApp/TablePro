import Foundation
@testable import TablePro
import Testing

@Suite("Window host selection")
struct WindowHostSelectionTests {
    private static let alpha = UUID()
    private static let beta = UUID()
    private static let gamma = UUID()

    /// The regression this guards: an inspector window in front made the host lookup fail, so
    /// opening a connection created a second window instead of adopting into the one that had it.
    @Test("A connection lands in the window already hosting it, whatever is in front")
    func owningHostWins() {
        let index = WindowHostSelection.hostIndex(
            forConnection: Self.beta,
            hostedConnections: [[Self.alpha], [Self.beta, Self.gamma]],
            frontmostIndex: 0
        )
        #expect(index == 1)
    }

    @Test("A new connection joins the frontmost window")
    func newConnectionJoinsFrontmost() {
        let index = WindowHostSelection.hostIndex(
            forConnection: Self.gamma,
            hostedConnections: [[Self.alpha], [Self.beta]],
            frontmostIndex: 1
        )
        #expect(index == 1)
    }

    /// A window has to be created only when there is genuinely none, which is what keeps the
    /// single-window promise honest.
    @Test("With no window open there is nothing to adopt into")
    func noHostMeansCreate() {
        let index = WindowHostSelection.hostIndex(
            forConnection: Self.alpha,
            hostedConnections: [],
            frontmostIndex: nil
        )
        #expect(index == nil)
    }

    @Test("With no window in front the first one still takes it, rather than a new one opening")
    func missingFrontmostFallsBackToFirst() {
        let index = WindowHostSelection.hostIndex(
            forConnection: Self.gamma,
            hostedConnections: [[Self.alpha], [Self.beta]],
            frontmostIndex: nil
        )
        #expect(index == 0)
    }

    @Test("A frontmost index outside the list does not select a window that is not there")
    func outOfRangeFrontmostIsSafe() {
        let index = WindowHostSelection.hostIndex(
            forConnection: Self.gamma,
            hostedConnections: [[Self.alpha]],
            frontmostIndex: 7
        )
        #expect(index == 0)
    }

    @Test("Opening a connection twice keeps landing in the same window")
    func repeatedOpensAreStable() {
        let hosted = [[Self.alpha], [Self.beta]]
        let first = WindowHostSelection.hostIndex(
            forConnection: Self.beta, hostedConnections: hosted, frontmostIndex: 0
        )
        let second = WindowHostSelection.hostIndex(
            forConnection: Self.beta, hostedConnections: hosted, frontmostIndex: 0
        )
        #expect(first == second)
        #expect(first == 1)
    }
}

import AppKit
@testable import TableProTextEngine
import Testing

@MainActor
struct ViewReuseQueueTests {
    private let superview = NSView()
    private let queue = ViewReuseQueue<NSView, Int>()

    private func place(_ keys: Range<Int>) {
        for key in keys {
            let view = queue.getOrCreateView(forKey: key) { NSView() }
            if view.superview == nil {
                superview.addSubview(view)
            }
        }
    }

    @Test
    func releasingMostViewsQueuesOnlyAsManyAsStayInUse() {
        place(0..<1_000)

        queue.enqueueViews(notInSet: Set(0..<10))

        #expect(queue.usedViews.count == 10)
        #expect(queue.queuedViews.count <= 10)
        #expect(superview.subviews.count <= 20)
        #expect(queue.queuedViews.allSatisfy { $0.isHidden && $0.superview === superview })
    }

    @Test
    func theNextPassReusesTheQueuedViews() {
        place(0..<1_000)
        queue.enqueueViews(notInSet: Set(0..<10))
        let queued = Set(queue.queuedViews.map { ObjectIdentifier($0) })
        #expect(!queued.isEmpty)

        place(1_000..<(1_000 + queued.count))

        let reused = (1_000..<(1_000 + queued.count)).compactMap { queue.getView(forKey: $0) }
        #expect(Set(reused.map { ObjectIdentifier($0) }) == queued)
        #expect(reused.allSatisfy { !$0.isHidden })
        #expect(queue.queuedViews.isEmpty)
    }

    @Test
    func keepingEveryViewReleasesNone() {
        place(0..<100)

        queue.enqueueViews(notInSet: Set(0..<100))

        #expect(queue.usedViews.count == 100)
        #expect(queue.queuedViews.isEmpty)
        #expect(superview.subviews.count == 100)
    }

    @Test
    func aQueueLeftFromATallerBandShrinksToTheViewsInUse() {
        place(0..<100)
        queue.enqueueViews(notInSet: Set(0..<50))
        #expect(queue.queuedViews.count == 50)

        queue.enqueueViews(notInSet: Set(0..<5))

        #expect(queue.usedViews.count == 5)
        #expect(queue.queuedViews.count <= 5)
        #expect(superview.subviews.count <= 10)
    }
}

import Foundation

/// The first `capacity` elements of a sequence in `areInIncreasingOrder`, kept without sorting the
/// rest. Equal elements keep the order they were inserted in, so the result is the same as a stable
/// `sorted(by:).prefix(capacity)`.
public struct TopRanked<Element> {
    private struct Entry {
        let element: Element
        let sequence: Int
    }

    public let capacity: Int
    private let areInIncreasingOrder: (Element, Element) -> Bool
    // A heap with the last kept entry at the root, so a better one replaces it in log time.
    private var heap: [Entry] = []
    private var inserted = 0

    public init(capacity: Int, by areInIncreasingOrder: @escaping (Element, Element) -> Bool) {
        self.capacity = max(0, capacity)
        self.areInIncreasingOrder = areInIncreasingOrder
        heap.reserveCapacity(min(self.capacity, 4_096))
    }

    public var count: Int { heap.count }

    public var isEmpty: Bool { heap.isEmpty }

    public mutating func insert(_ element: Element) {
        let entry = Entry(element: element, sequence: inserted)
        inserted += 1
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(entry)
            siftUp(from: heap.count - 1)
        } else if precedes(entry, heap[0]) {
            heap[0] = entry
            siftDown(from: 0)
        }
    }

    public func sorted() -> [Element] {
        heap.sorted(by: precedes).map(\.element)
    }

    private func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if areInIncreasingOrder(lhs.element, rhs.element) { return true }
        if areInIncreasingOrder(rhs.element, lhs.element) { return false }
        return lhs.sequence < rhs.sequence
    }

    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(heap[parent], heap[child]) else { return }
            heap.swapAt(parent, child)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = 2 * parent + 1
            guard left < heap.count else { return }
            var last = left
            let right = left + 1
            if right < heap.count, precedes(heap[left], heap[right]) { last = right }
            guard precedes(heap[parent], heap[last]) else { return }
            heap.swapAt(parent, last)
            parent = last
        }
    }
}

@testable import TableProUtilities
import Testing

struct TopRankedTests {
    private struct Entry: Equatable {
        let key: Int
        let tag: Int
    }

    private func reference(_ entries: [Entry], capacity: Int) -> [Entry] {
        Array(entries.enumerated()
            .sorted { lhs, rhs in
                lhs.element.key != rhs.element.key ? lhs.element.key < rhs.element.key : lhs.offset < rhs.offset
            }
            .prefix(capacity)
            .map(\.element))
    }

    @Test("Keeps the same entries in the same order as a stable sort's prefix, ties included")
    func matchesStableSortedPrefix() {
        var generator = SystemRandomNumberGenerator()
        for capacity in [0, 1, 2, 7, 50, 200, 1_000] {
            for _ in 0..<20 {
                let entries = (0..<Int.random(in: 0...600, using: &generator)).map { tag in
                    Entry(key: Int.random(in: 0..<40, using: &generator), tag: tag)
                }
                var top = TopRanked<Entry>(capacity: capacity) { $0.key < $1.key }
                for entry in entries { top.insert(entry) }
                #expect(top.sorted() == reference(entries, capacity: capacity))
                #expect(top.count == min(capacity, entries.count))
            }
        }
    }

    @Test("Equal entries keep insertion order")
    func tiesKeepInsertionOrder() {
        var top = TopRanked<Entry>(capacity: 3) { $0.key < $1.key }
        for tag in 0..<10 { top.insert(Entry(key: 1, tag: tag)) }
        #expect(top.sorted().map(\.tag) == [0, 1, 2])
    }
}

import Foundation
@testable import TableProEditorKit
import Testing

@MainActor
struct StyledRangeContainerTests {
    typealias Run = RangeStoreRun<StyledRangeContainer.StyleElement>

    @MainActor
    @Test func test_init() {
        let providers = [0, 1]
        let store = StyledRangeContainer(documentLength: 100, providers: providers)

        // Have to do string conversion due to missing Comparable conformance pre-macOS 14
        #expect(store.providerStores.keys.sorted() == providers)
        #expect(store.providerStores.values.allSatisfy({ $0.store.length == 100 }), "One or more providers have incorrect length")
    }

    @MainActor
    @Test func test_setHighlights() throws {
        let providers = [0, 1]
        let store = StyledRangeContainer(documentLength: 100, providers: providers)

        store.applyHighlightResult(
            provider: providers[0],
            highlights: [HighlightRange(range: NSRange(location: 40, length: 10), capture: .comment)],
            rangeToHighlight: NSRange(location: 0, length: 100)
        )

        let storage = try #require(store.providerStores[providers[0]])
        #expect(storage.store.runCount == 3)

        let runs = storage.store.runs(in: 0..<100)
        #expect(runs[0].value?.capture == nil)
        #expect(runs[1].value?.capture == .comment)
        #expect(runs[2].value?.capture == nil)

        #expect(store.runsIn(range: NSRange(location: 0, length: 100)) == [
            Run(length: 40, value: nil),
            Run(length: 10, value: .init(capture: .comment, modifiers: [])),
            Run(length: 50, value: nil)
        ])
    }

    @MainActor
    @Test func test_overlappingRuns() {
        let providers = [0, 1]
        let store = StyledRangeContainer(documentLength: 100, providers: providers)

        store.applyHighlightResult(
            provider: providers[0],
            highlights: [HighlightRange(range: NSRange(location: 40, length: 10), capture: .comment)],
            rangeToHighlight: NSRange(location: 0, length: 100)
        )

        store.applyHighlightResult(
            provider: providers[1],
            highlights: [
                HighlightRange(range: NSRange(location: 45, length: 5), capture: nil, modifiers: [.declaration])
            ],
            rangeToHighlight: NSRange(location: 0, length: 100)
        )

        #expect(store.runsIn(range: NSRange(location: 0, length: 100)) == [
            Run(length: 40, value: nil),
            Run(length: 5, value: .init(capture: .comment, modifiers: [])),
            Run(length: 5, value: .init(capture: .comment, modifiers: [.declaration])),
            Run(length: 50, value: nil)
        ])
    }

    @MainActor
    @Test func test_overlappingRunsWithMoreProviders() {
        let providers = [0, 1, 2]
        let store = StyledRangeContainer(documentLength: 200, providers: providers)

        store.applyHighlightResult(
            provider: providers[0],
            highlights: [
                HighlightRange(range: NSRange(location: 30, length: 20), capture: .comment),
                HighlightRange(range: NSRange(location: 80, length: 30), capture: .string)
            ],
            rangeToHighlight: NSRange(location: 0, length: 200)
        )

        store.applyHighlightResult(
            provider: providers[1],
            highlights: [
                HighlightRange(range: NSRange(location: 35, length: 10), capture: nil, modifiers: [.declaration]),
                HighlightRange(range: NSRange(location: 90, length: 15), capture: .comment, modifiers: [.static])
            ],
            rangeToHighlight: NSRange(location: 0, length: 200)
        )

        store.applyHighlightResult(
            provider: providers[2],
            highlights: [
                HighlightRange(range: NSRange(location: 40, length: 5), capture: .function, modifiers: [.abstract]),
                HighlightRange(range: NSRange(location: 100, length: 10), capture: .number, modifiers: [.modification])
            ],
            rangeToHighlight: NSRange(location: 0, length: 200)
        )

        let runs = store.runsIn(range: NSRange(location: 0, length: 200))

        #expect(runs.reduce(0, { $0 + $1.length}) == 200)

        #expect(runs[0] == Run(length: 30, value: nil))
        #expect(runs[1] == Run(length: 5, value: .init(capture: .comment, modifiers: [])))
        #expect(runs[2] == Run(length: 5, value: .init(capture: .comment, modifiers: [.declaration])))
        #expect(runs[3] == Run(length: 5, value: .init(capture: .comment, modifiers: [.abstract, .declaration])))
        #expect(runs[4] == Run(length: 5, value: .init(capture: .comment, modifiers: [])))
        #expect(runs[5] == Run(length: 30, value: nil))
        #expect(runs[6] == Run(length: 10, value: .init(capture: .string, modifiers: [])))
        #expect(runs[7] == Run(length: 10, value: .init(capture: .string, modifiers: [.static])))
        #expect(runs[8] == Run(length: 5, value: .init(capture: .string, modifiers: [.static, .modification])))
        #expect(runs[9] == Run(length: 5, value: .init(capture: .string, modifiers: [.modification])))
        #expect(runs[10] == Run(length: 90, value: nil))
    }
}

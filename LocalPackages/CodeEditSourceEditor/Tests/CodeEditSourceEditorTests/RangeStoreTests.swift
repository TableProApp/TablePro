import Testing
@testable import CodeEditSourceEditor

extension RangeStore {
    var length: Int { _guts.summary.length }
    var count: Int { _guts.count }
}

@Suite
struct RangeStoreTests {
    typealias Store = RangeStore<StyledRangeContainer.StyleElement>

    @Test
    func initWithLength() {
        for _ in 0..<100 {
            let length = Int.random(in: 0..<1000)
            let store = Store(documentLength: length)
            #expect(store.length == length)
        }
    }

    // MARK: - Storage

    @Test
    func storageRemoveCharacters() {
        var store = Store(documentLength: 100)
        store.storageUpdated(replacedCharactersIn: 10..<12, withCount: 0)
        #expect(store.length == 98, "Failed to remove correct range")
        #expect(store.count == 1, "Failed to coalesce")
    }

    @Test
    func storageRemoveFromEnd() {
        var store = Store(documentLength: 100)
        store.storageUpdated(replacedCharactersIn: 95..<100, withCount: 0)
        #expect(store.length == 95, "Failed to remove correct range")
        #expect(store.count == 1, "Failed to coalesce")
    }

    @Test
    func storageRemoveSingleCharacterFromEnd() {
        var store = Store(documentLength: 10)
        store.set( // Test that we can delete a character associated with a single syntax run too
            runs: [
                .empty(length: 8),
                .init(length: 1, value: .init(modifiers: [.abstract])),
                .init(length: 1, value: .init(modifiers: [.declaration]))
            ],
            for: 0..<10
        )
        store.storageUpdated(replacedCharactersIn: 9..<10, withCount: 0)
        #expect(store.length == 9, "Failed to remove correct range")
        #expect(store.count == 2)
    }

    @Test
    func storageRemoveFromBeginning() {
        var store = Store(documentLength: 100)
        store.storageUpdated(replacedCharactersIn: 0..<15, withCount: 0)
        #expect(store.length == 85, "Failed to remove correct range")
        #expect(store.count == 1, "Failed to coalesce")
    }

    @Test
    func storageRemoveAll() {
        var store = Store(documentLength: 100)
        store.storageUpdated(replacedCharactersIn: 0..<100, withCount: 0)
        #expect(store.length == 0, "Failed to remove correct range")
        #expect(store.count == 0, "Failed to remove all runs")
    }

    @Test
    func storageInsert() {
        var store = Store(documentLength: 100)
        store.storageUpdated(replacedCharactersIn: 45..<45, withCount: 10)
        #expect(store.length == 110)
        #expect(store.count == 1, "Failed to coalesce")
    }

    @Test
    func storageInsertAtEnd() {
        var store = Store(documentLength: 100)
        store.storageUpdated(replacedCharactersIn: 100..<100, withCount: 10)
        #expect(store.length == 110)
        #expect(store.count == 1, "Failed to coalesce")
    }

    @Test
    func storageInsertAtBeginning() {
        var store = Store(documentLength: 100)
        store.storageUpdated(replacedCharactersIn: 0..<0, withCount: 10)
        #expect(store.length == 110)
        #expect(store.count == 1, "Failed to coalesce")
    }

    @Test
    func storageInsertFromEmpty() {
        var store = Store(documentLength: 0)
        store.storageUpdated(replacedCharactersIn: 0..<0, withCount: 10)
        #expect(store.length == 10)
        #expect(store.count == 1, "Failed to coalesce")
    }

    @Test
    func storageEdit() {
        var store = Store(documentLength: 100)
        store.storageUpdated(replacedCharactersIn: 45..<50, withCount: 10)
        #expect(store.length == 105)
        #expect(store.count == 1, "Failed to coalesce")
    }

    @Test
    func storageEditAtEnd() {
        var store = Store(documentLength: 100)
        store.storageUpdated(replacedCharactersIn: 95..<100, withCount: 10)
        #expect(store.length == 105)
        #expect(store.count == 1, "Failed to coalesce")
    }

    @Test
    func storageEditAtBeginning() {
        var store = Store(documentLength: 100)
        store.storageUpdated(replacedCharactersIn: 0..<5, withCount: 10)
        #expect(store.length == 105)
        #expect(store.count == 1, "Failed to coalesce")
    }

    @Test
    func storageEditAll() {
        var store = Store(documentLength: 100)
        store.storageUpdated(replacedCharactersIn: 0..<100, withCount: 10)
        #expect(store.length == 10)
        #expect(store.count == 1, "Failed to coalesce")
    }

    // MARK: - Styles

    @Test
    func setOneRun() {
        var store = Store(documentLength: 100)
        store.set(value: .init(capture: .comment, modifiers: [.static]), for: 45..<50)
        #expect(store.length == 100)
        #expect(store.count == 3)

        let runs = store.runs(in: 0..<100)
        #expect(runs.count == 3)
        #expect(runs[0].length == 45)
        #expect(runs[1].length == 5)
        #expect(runs[2].length == 50)

        #expect(runs[0].value?.capture == nil)
        #expect(runs[1].value?.capture == .comment)
        #expect(runs[2].value?.capture == nil)

        #expect(runs[0].value?.modifiers == nil)
        #expect(runs[1].value?.modifiers == [.static])
        #expect(runs[2].value?.modifiers == nil)
    }

    @Test
    func queryOverlappingRun() {
        var store = Store(documentLength: 100)
        store.set(value: .init(capture: .comment, modifiers: [.static]), for: 45..<50)
        #expect(store.length == 100)
        #expect(store.count == 3)

        let runs = store.runs(in: 47..<100)
        #expect(runs.count == 2)
        #expect(runs[0].length == 3)
        #expect(runs[1].length == 50)

        #expect(runs[0].value?.capture == .comment)
        #expect(runs[1].value?.capture == nil)

        #expect(runs[0].value?.modifiers == [.static])
        #expect(runs[1].value?.modifiers == nil)
    }

    @Test
    func setMultipleRuns() {
        var store = Store(documentLength: 100)

        store.set(value: .init(capture: .comment, modifiers: [.static]), for: 5..<15)
        store.set(value: .init(capture: .keyword, modifiers: []), for: 20..<30)
        store.set(value: .init(capture: .string, modifiers: [.static]), for: 35..<40)
        store.set(value: .init(capture: .function, modifiers: []), for: 45..<50)
        store.set(value: .init(capture: .variable, modifiers: []), for: 60..<70)

        #expect(store.length == 100)

        let runs = store.runs(in: 0..<100)
        #expect(runs.count == 11)
        #expect(runs.reduce(0, { $0 + $1.length }) == 100)

        let lengths = [5, 10, 5, 10, 5, 5, 5, 5, 10, 10, 30]
        let captures: [CaptureName?] = [nil, .comment, nil, .keyword, nil, .string, nil, .function, nil, .variable, nil]
        let modifiers: [CaptureModifierSet] = [[], [.static], [], [], [], [.static], [], [], [], [], []]

        runs.enumerated().forEach {
            #expect($0.element.length == lengths[$0.offset])
            #expect($0.element.value?.capture == captures[$0.offset])
            #expect($0.element.value?.modifiers ?? [] == modifiers[$0.offset])
        }
    }

    @Test
    func setMultipleRunsAndStorageUpdate() {
        var store = Store(documentLength: 100)

        var lengths = [5, 10, 5, 10, 5, 5, 5, 5, 10, 10, 30]
        var captures: [CaptureName?] = [nil, .comment, nil, .keyword, nil, .string, nil, .function, nil, .variable, nil]
        var modifiers: [CaptureModifierSet] = [[], [.static], [], [], [], [.static], [], [], [], [], []]

        store.set(
            runs: zip(zip(lengths, captures), modifiers).map {
                Store.Run(length: $0.0, value: .init(capture: $0.1, modifiers: $1))
            },
            for: 0..<100
        )

        #expect(store.length == 100)

        var runs = store.runs(in: 0..<100)
        #expect(runs.count == 11)
        #expect(runs.reduce(0, { $0 + $1.length }) == 100)

        runs.enumerated().forEach {
            #expect(
                $0.element.length == lengths[$0.offset],
                "Run \($0.offset) has incorrect length: \($0.element.length). Expected \(lengths[$0.offset])"
            )
            #expect(
                $0.element.value?.capture == captures[$0.offset], // swiftlint:disable:next line_length
                "Run \($0.offset) has incorrect capture: \(String(describing: $0.element.value?.capture)). Expected \(String(describing: captures[$0.offset]))"
            )
            #expect(
                $0.element.value?.modifiers == modifiers[$0.offset], // swiftlint:disable:next line_length
                "Run \($0.offset) has incorrect modifiers: \(String(describing: $0.element.value?.modifiers)). Expected \(modifiers[$0.offset])"
            )
        }

        store.storageUpdated(replacedCharactersIn: 30..<45, withCount: 10)
        runs = store.runs(in: 0..<95)
        #expect(runs.count == 9)
        #expect(runs.reduce(0, { $0 + $1.length }) == 95)

        lengths = [5, 10, 5, 10, 10, 5, 10, 10, 30]
        captures = [nil, .comment, nil, .keyword, nil, .function, nil, .variable, nil]
        modifiers = [[], [.static], [], [], [], [], [], [], []]

        runs.enumerated().forEach {
            #expect($0.element.length == lengths[$0.offset])
            #expect($0.element.value?.capture == captures[$0.offset])
            #expect($0.element.value?.modifiers ?? [] == modifiers[$0.offset])
        }
    }

    // MARK: - Query

    // A few known bad cases
    @Test(arguments: [3..<8, 65..<100, 0..<5, 5..<12])
    func runsInAlwaysBoundedByRange(_ range: Range<Int>) {
        var store = Store(documentLength: 100)
        let lengths = [5, 10, 5, 10, 5, 5, 5, 5, 10, 10, 30]
        let captures: [CaptureName?] = [nil, .comment, nil, .keyword, nil, .string, nil, .function, nil, .variable, nil]
        let modifiers: [CaptureModifierSet] = [[], [.static], [], [], [], [.static], [], [], [], [], []]

        store.set(
            runs: zip(zip(lengths, captures), modifiers).map {
                Store.Run(length: $0.0, value: .init(capture: $0.1, modifiers: $1))
            },
            for: 0..<100
        )

        #expect(
            store.runs(in: range).reduce(0, { $0 + $1.length }) == (range.upperBound - range.lowerBound),
            "Runs returned by storage did not equal requested range"
        )
        #expect(store.runs(in: range).allSatisfy({ $0.length > 0 }))
    }

    // Randomized version of the previous test
    @Test
    func runsAlwaysBoundedByRangeRandom() {
        func range() -> Range<Int> {
            let start = Int.random(in: 0..<100)
            let end = Int.random(in: start..<100)
            return start..<end
        }

        for _ in 0..<1000 {
            runsInAlwaysBoundedByRange(range())
        }
    }
}

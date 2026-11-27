import Foundation

// Row ids in order, consecutive existing ids held as one range, so a million selected rows are one entry.
struct RowIDRuns: Hashable, Sendable {
    fileprivate enum Run: Hashable, Sendable {
        case existing(Range<Int>)
        case inserted(UUID)
    }

    private var runs: [Run] = []
    private(set) var count = 0

    init() {}

    init(_ ids: some Sequence<RowID>) {
        for id in ids {
            append(id)
        }
    }

    var isEmpty: Bool { runs.isEmpty }
    var runCount: Int { runs.count }

    mutating func append(_ id: RowID) {
        count += 1
        switch id {
        case .existing(let index):
            if case .existing(let last)? = runs.last, last.upperBound == index {
                runs[runs.count - 1] = .existing(last.lowerBound..<(index + 1))
            } else {
                runs.append(.existing(index..<(index + 1)))
            }
        case .inserted(let uuid):
            runs.append(.inserted(uuid))
        }
    }

    // The open run stays in locals, so the array is written only where a run ends.
    mutating func append(rowsIn rows: UnsafeBufferPointer<Row>) {
        var open: Range<Int>?
        for index in rows.indices {
            switch rows[index].id {
            case .existing(let id):
                if let current = open, current.upperBound == id {
                    open = current.lowerBound..<(id + 1)
                } else {
                    if let current = open { appendExisting(current) }
                    open = id..<(id + 1)
                }
            case .inserted(let uuid):
                if let current = open { appendExisting(current) }
                open = nil
                append(.inserted(uuid))
            }
        }
        if let open { appendExisting(open) }
    }

    private mutating func appendExisting(_ range: Range<Int>) {
        count += range.count
        if case .existing(let last)? = runs.last, last.upperBound == range.lowerBound {
            runs[runs.count - 1] = .existing(last.lowerBound..<range.upperBound)
        } else {
            runs.append(.existing(range))
        }
    }
}

extension RowIDRuns: Sequence {
    struct Iterator: IteratorProtocol {
        private let runs: [Run]
        private var runIndex = 0
        private var nextExisting: Int?

        fileprivate init(runs: [Run]) {
            self.runs = runs
        }

        mutating func next() -> RowID? {
            while runIndex < runs.count {
                switch runs[runIndex] {
                case .inserted(let uuid):
                    runIndex += 1
                    return .inserted(uuid)
                case .existing(let range):
                    let id = nextExisting ?? range.lowerBound
                    guard id < range.upperBound else {
                        runIndex += 1
                        nextExisting = nil
                        continue
                    }
                    nextExisting = id + 1
                    return .existing(id)
                }
            }
            return nil
        }
    }

    func makeIterator() -> Iterator {
        Iterator(runs: runs)
    }

    var underestimatedCount: Int { count }
}

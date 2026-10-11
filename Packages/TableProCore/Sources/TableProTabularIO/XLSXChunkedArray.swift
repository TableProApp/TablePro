import Foundation

struct XLSXChunkedArray<Element: Sendable>: Sendable {
    private static var blockShift: Int { 16 }
    private static var blockSize: Int { 1 << blockShift }
    private static var blockMask: Int { blockSize - 1 }

    private var blocks: [[Element]] = []
    private(set) var count = 0

    init() {}

    init<Source: Sequence>(_ elements: Source) where Source.Element == Element {
        for element in elements {
            append(element)
        }
    }

    var isEmpty: Bool { blocks.isEmpty }

    subscript(index: Int) -> Element {
        get { blocks[index >> Self.blockShift][index & Self.blockMask] }
        set { blocks[index >> Self.blockShift][index & Self.blockMask] = newValue }
    }

    mutating func append(_ element: Element) {
        if count.isMultiple(of: Self.blockSize) {
            var block: [Element] = []
            if !blocks.isEmpty { block.reserveCapacity(Self.blockSize) }
            blocks.append(block)
        }
        blocks[blocks.count - 1].append(element)
        count += 1
    }

    mutating func append(_ element: Element, times: Int) {
        for _ in 0..<max(0, times) {
            append(element)
        }
    }

    func firstIndex(where predicate: (Element) -> Bool) -> Int? {
        var base = 0
        for block in blocks {
            if let offset = block.firstIndex(where: predicate) { return base + offset }
            base += block.count
        }
        return nil
    }

    func lastIndex(where predicate: (Element) -> Bool) -> Int? {
        var base = count
        for block in blocks.reversed() {
            base -= block.count
            if let offset = block.lastIndex(where: predicate) { return base + offset }
        }
        return nil
    }
}

extension XLSXChunkedArray where Element: Comparable {
    func lowerBound(of target: Element) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle] < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

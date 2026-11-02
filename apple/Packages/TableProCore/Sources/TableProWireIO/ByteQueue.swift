public struct ByteQueue: Sendable {
    private var storage: [UInt8] = []
    private var head = 0

    private static let compactionThreshold = 64 * 1_024

    public init() {}

    public var count: Int { storage.count - head }
    public var isEmpty: Bool { head == storage.count }

    public subscript(position: Int) -> UInt8 {
        storage[head + position]
    }

    public mutating func append(contentsOf bytes: some Sequence<UInt8>) {
        storage.append(contentsOf: bytes)
    }

    public func prefix(_ length: Int) -> [UInt8] {
        Array(storage[head..<(head + min(max(length, 0), count))])
    }

    @discardableResult
    public mutating func removeFirst(_ length: Int) -> [UInt8] {
        let taken = prefix(length)
        head += taken.count
        compactIfNeeded()
        return taken
    }

    public func firstIndex(of byte: UInt8, from start: Int = 0) -> Int? {
        let lower = head + min(max(start, 0), count)
        return storage[lower...].firstIndex(of: byte).map { $0 - head }
    }

    public func firstRange(of pattern: [UInt8], from start: Int = 0) -> Range<Int>? {
        guard let first = pattern.first, pattern.count <= count else { return nil }
        var candidate = min(max(start, 0), count)
        while let found = firstIndex(of: first, from: candidate), found + pattern.count <= count {
            if storage[(head + found)..<(head + found + pattern.count)].elementsEqual(pattern) {
                return found..<(found + pattern.count)
            }
            candidate = found + 1
        }
        return nil
    }

    // Moving the unread tail only once the consumed head is both large and at least half the
    // storage keeps every byte's share of the copying constant.
    private mutating func compactIfNeeded() {
        if head == storage.count {
            storage.removeAll(keepingCapacity: storage.capacity <= Self.compactionThreshold * 16)
            head = 0
        } else if head >= Self.compactionThreshold, head * 2 >= storage.count {
            storage.removeSubrange(0..<head)
            head = 0
        }
    }
}

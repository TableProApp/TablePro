import Foundation

enum XLSXStreamingParse {
    static let defaultChunkSize = 1 << 20
    static let largestElement = 64 << 20

    static func run(
        _ archive: ZipArchive,
        entry: ZipArchive.Entry,
        chunkSize: Int,
        progress: ((Double) -> Void)?,
        isCancelled: () -> Bool,
        consume: (UnsafeBufferPointer<UInt8>, Bool) -> Int
    ) throws {
        try archive.withReader(for: entry) { reader in
            var window = ParseWindow(capacity: max(1, chunkSize))
            defer { window.deallocate() }
            while true {
                if isCancelled() { throw TabularCancellation() }
                if window.isFull {
                    guard window.capacity < largestElement else {
                        throw ZipArchive.Failure.corruptEntry(entry.path)
                    }
                    window.grow()
                }
                let produced = try reader.read(into: window.freeSpace)
                window.filled += produced
                let isFinal = produced == 0
                let consumed = consume(window.contents, isFinal)
                if isFinal { return }
                window.discard(consumed)
                progress?(reader.fractionConsumed)
            }
        }
    }
}

private struct ParseWindow {
    private(set) var storage: UnsafeMutableBufferPointer<UInt8>
    var filled = 0

    init(capacity: Int) {
        storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: capacity)
    }

    var capacity: Int { storage.count }
    var isFull: Bool { filled == storage.count }
    var freeSpace: UnsafeMutableBufferPointer<UInt8> { UnsafeMutableBufferPointer(rebasing: storage[filled...]) }
    var contents: UnsafeBufferPointer<UInt8> { UnsafeBufferPointer(rebasing: storage[0..<filled]) }

    mutating func grow() {
        let larger = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: storage.count * 2)
        if let source = storage.baseAddress, let destination = larger.baseAddress {
            UnsafeMutableRawPointer(destination).copyMemory(from: source, byteCount: filled)
        }
        storage.deallocate()
        storage = larger
    }

    mutating func discard(_ count: Int) {
        guard count > 0, let base = storage.baseAddress else { return }
        let remaining = filled - count
        if remaining > 0 {
            UnsafeMutableRawPointer(base).copyMemory(from: base + count, byteCount: remaining)
        }
        filled = remaining
    }

    func deallocate() {
        storage.deallocate()
    }
}

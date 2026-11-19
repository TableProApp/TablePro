import TableProMemcachedCore
import Testing

private func entries(_ count: Int, keyLength: Int = 12, size: Int? = 100) -> [MemcachedKeyEntry] {
    (0 ..< count).map { index in
        let suffix = String(index)
        let padding = String(repeating: "k", count: max(0, keyLength - suffix.count))
        return MemcachedKeyEntry(key: padding + suffix, expiresAt: nil, flags: nil, size: size)
    }
}

struct MemcachedValueBatchesTests {
    @Test("A page of 1,000 ordinary keys is read in one gets")
    func pageIsOneRequest() {
        #expect(MemcachedValueBatches.split(entries(1_000)).count == 1)
    }

    @Test("Key 1,001 starts a second gets")
    func keyLimitStartsANewRequest() {
        #expect(MemcachedValueBatches.split(entries(1_001)).map(\.count) == [1_000, 1])
    }

    @Test("Every key is read once, in listing order")
    func keysKeepTheirOrder() {
        let listed = entries(2_500, keyLength: 200)
        #expect(MemcachedValueBatches.split(listed).flatMap { $0 } == listed.map(\.key))
    }

    @Test("Long keys keep every request line within 64 KiB")
    func longKeysSplitTheLine() throws {
        let batches = MemcachedValueBatches.split(entries(1_000, keyLength: 250))
        #expect(batches.count > 1)
        for keys in batches {
            let command = MemcachedCommand.get(keys: keys, withCAS: true)
            #expect(command.wireBytes.count <= 64 * 1_024)
        }
    }

    @Test("Large listed items spread over several requests")
    func largeItemsSplitTheReply() {
        let batches = MemcachedValueBatches.split(entries(1_000, size: 1_024 * 1_024))
        #expect(batches.map(\.count) == Array(repeating: 16, count: 62) + [8])
    }

    @Test("An item over the byte limit by itself is still read")
    func oversizedItemGoesAlone() {
        let listed = entries(3, size: 32 * 1_024 * 1_024)
        #expect(MemcachedValueBatches.split(listed).map(\.count) == [1, 1, 1])
    }

    @Test("Items the listing gives no size for count only as keys")
    func unknownSizesDoNotSplit() {
        #expect(MemcachedValueBatches.split(entries(1_000, size: nil)).count == 1)
    }

    @Test("A size no server could report does not overflow the sum")
    func absurdSizeDoesNotTrap() {
        let listed = entries(3, size: .max)
        #expect(MemcachedValueBatches.split(listed).flatMap { $0 } == listed.map(\.key))
    }

    @Test("No keys, no requests")
    func noKeysNoRequests() {
        #expect(MemcachedValueBatches.split([MemcachedKeyEntry]()).isEmpty)
    }
}

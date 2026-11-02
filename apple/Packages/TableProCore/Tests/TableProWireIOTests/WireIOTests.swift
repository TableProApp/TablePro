import TableProWireIO
import Testing

@Test func readsBigEndianIntegers() throws {
    var reader = ByteReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F])
    #expect(try reader.u8() == 0x01)
    #expect(try reader.u16() == 0x0203)
    #expect(try reader.u32() == 0x0405_0607)
    #expect(try reader.u64() == 0x0809_0A0B_0C0D_0E0F)
    #expect(reader.isAtEnd)
}

@Test func takeRejectsANegativeCount() {
    var reader = ByteReader([0x00, 0x78])
    _ = try? reader.u8()
    #expect(throws: WireIOError.lengthOutOfRange("-1", limit: 1)) { try reader.take(-1) }
    #expect(throws: WireIOError.lengthOutOfRange("-1", limit: 1)) { try reader.skip(-1) }
    #expect(reader.offset == 1)
}

@Test func takeRejectsACountPastTheBytes() {
    var reader = ByteReader([0x01, 0x02])
    #expect(throws: WireIOError.truncated(needed: 3, available: 2)) { try reader.take(3) }
    #expect(throws: WireIOError.lengthOutOfRange("18446744073709551615", limit: 2)) { try reader.take(UInt64.max) }
}

@Test func elementCountIsBoundedByTheBytesLeft() throws {
    let reader = ByteReader([UInt8](repeating: 0, count: 16))
    #expect(try reader.elementCount(Int32(4), minimumElementSize: 4) == 4)
    #expect(throws: WireIOError.self) { try reader.elementCount(Int32(5), minimumElementSize: 4) }
    #expect(throws: WireIOError.self) { try reader.elementCount(Int32(-1), minimumElementSize: 1) }
}

@Test func checkedLengthNarrowsWithoutTrapping() throws {
    #expect(try WireLength.checked(UInt64(64), limit: 64) == 64)
    #expect(throws: WireIOError.self) { try WireLength.checked(UInt64.max, limit: .max) }
    #expect(throws: WireIOError.self) { try WireLength.checked(Int64(-1), limit: 10) }
    #expect(throws: WireIOError.self) { try WireLength.checked(65, limit: 64) }
}

@Test func queueHandsBackBytesInOrder() {
    var queue = ByteQueue()
    queue.append(contentsOf: [1, 2, 3, 4, 5])
    #expect(queue.removeFirst(2) == [1, 2])
    queue.append(contentsOf: [6])
    #expect(queue.count == 4)
    #expect(queue[0] == 3)
    #expect(queue.prefix(10) == [3, 4, 5, 6])
    #expect(queue.removeFirst(10) == [3, 4, 5, 6])
    #expect(queue.isEmpty)
}

@Test func queueFindsAPatternFromAnOffset() {
    var queue = ByteQueue()
    queue.append(contentsOf: Array("xx\r\n\r\nyy\r\n\r\n".utf8))
    #expect(queue.firstRange(of: [0x0D, 0x0A, 0x0D, 0x0A]) == 2..<6)
    #expect(queue.firstRange(of: [0x0D, 0x0A, 0x0D, 0x0A], from: 3) == 8..<12)
    #expect(queue.firstIndex(of: 0x79) == 6)
    queue.removeFirst(6)
    #expect(queue.firstRange(of: [0x0D, 0x0A, 0x0D, 0x0A]) == 2..<6)
}

@Test func drainingManySmallMessagesStaysLinear() {
    var queue = ByteQueue()
    let message: [UInt8] = [0x8A, 0x00]
    for _ in 0..<(1 << 19) { queue.append(contentsOf: message) }
    var drained = 0
    while !queue.isEmpty {
        drained += queue.removeFirst(2).count
    }
    #expect(drained == 1 << 20)
}

@Test func budgetAllowsOutputInsideTheGrace() throws {
    var budget = DecompressionBudget(ratioLimit: 250, grace: 1_000)
    try budget.record(produced: 1_000, consumed: 1)
    #expect(budget.produced == 1_000)
}

@Test func budgetRefusesARatioPastTheGrace() {
    var budget = DecompressionBudget(ratioLimit: 250, grace: 1_000)
    #expect(throws: WireIOError.expansionExceeded(produced: 1_001, consumed: 1)) {
        try budget.record(produced: 1_001, consumed: 1)
    }
}

@Test func budgetRefusesOutputPastTheLimitAcrossCalls() throws {
    var budget = DecompressionBudget(limit: 100, ratioLimit: .max, grace: .max)
    try budget.record(produced: 60, consumed: 10)
    #expect(throws: WireIOError.self) { try budget.record(produced: 60, consumed: 10) }
}

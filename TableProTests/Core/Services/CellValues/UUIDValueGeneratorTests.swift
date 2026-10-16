//
//  UUIDValueGeneratorTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct UUIDValueGeneratorTests {
    private static func bytes(of uuid: UUID) -> [UInt8] {
        withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    @Test("Version 4 carries version 4 and the RFC variant")
    func version4Bits() {
        let bytes = Self.bytes(of: UUIDValueGenerator().make(.v4))
        #expect(bytes[6] >> 4 == 4)
        #expect(bytes[8] >> 6 == 0b10)
    }

    @Test("Version 7 carries version 7, the RFC variant and the Unix millisecond time")
    func version7Bits() {
        let instant = Date(timeIntervalSince1970: 1_760_600_000.123)
        let bytes = Self.bytes(of: UUIDValueGenerator(now: { instant }).make(.v7))
        let milliseconds = bytes[0..<6].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        #expect(milliseconds == 1_760_600_000_123)
        #expect(bytes[6] >> 4 == 7)
        #expect(bytes[8] >> 6 == 0b10)
    }

    @Test("Version 7 values made inside one millisecond still sort in creation order")
    func version7BurstIsMonotonic() {
        let instant = Date(timeIntervalSince1970: 1_760_600_000)
        let generator = UUIDValueGenerator(now: { instant })
        let values = (0..<5_000).map { _ in generator.make(.v7).uuidString.lowercased() }
        #expect(values == values.sorted())
        #expect(Set(values).count == values.count)
    }

    @Test("Version 7 never goes backwards when the clock does")
    func version7SurvivesClockStepBack() {
        let clock = SteppingClock(Date(timeIntervalSince1970: 1_760_600_000))
        let generator = UUIDValueGenerator(now: { clock.current })
        let first = generator.make(.v7).uuidString.lowercased()
        clock.current = Date(timeIntervalSince1970: 1_760_599_000)
        let second = generator.make(.v7).uuidString.lowercased()
        #expect(first < second)
    }
}

private final class SteppingClock: @unchecked Sendable {
    var current: Date

    init(_ current: Date) {
        self.current = current
    }
}

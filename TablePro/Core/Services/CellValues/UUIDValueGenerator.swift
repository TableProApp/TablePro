//
//  UUIDValueGenerator.swift
//  TablePro
//

import Foundation

enum UUIDVersion: Sendable, CaseIterable {
    case v4
    case v7
}

/// Makes the UUIDs the grid, the inspector and Fill Column write into a cell. Foundation makes only
/// version 4, so version 7 is built here from RFC 9562 section 5.7.
final class UUIDValueGenerator: @unchecked Sendable {
    static let shared = UUIDValueGenerator()

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    /// The last v7 timestamp handed out: Unix milliseconds shifted left 12, plus the sub-millisecond
    /// fraction in the low 12 bits (RFC 9562 section 6.2, Method 3). A burst inside one tick, such as
    /// Fill Column over a thousand rows, takes the next tick, so the values still sort in creation order.
    private var lastTick: UInt64 = 0

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func make(_ version: UUIDVersion) -> UUID {
        switch version {
        case .v4: UUID()
        case .v7: makeVersion7()
        }
    }

    private func makeVersion7() -> UUID {
        // Rounded to the microsecond: the Double behind a Date holds 0.123 s as 0.122999808, and truncating that
        // lands in the millisecond before.
        let microseconds = UInt64((max(0, now().timeIntervalSince1970) * 1_000_000).rounded())
        var tick = (microseconds / 1_000) << 12 | ((microseconds % 1_000) * 4_096 / 1_000)
        lock.lock()
        if tick <= lastTick {
            tick = lastTick + 1
        }
        lastTick = tick
        lock.unlock()

        var generator = SystemRandomNumberGenerator()
        let random: UInt64 = generator.next()
        let milliseconds = tick >> 12
        let randA = tick & 0x0FFF

        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * (5 - index)))
        }
        bytes[6] = 0x70 | UInt8(truncatingIfNeeded: randA >> 8)
        bytes[7] = UInt8(truncatingIfNeeded: randA)
        for index in 0..<8 {
            bytes[8 + index] = UInt8(truncatingIfNeeded: random >> (8 * (7 - index)))
        }
        bytes[8] = 0x80 | (bytes[8] & 0x3F)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

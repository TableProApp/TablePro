//
//  TimestampValueTests.swift
//  TableProTests
//
//  `DateFormatter` clamps a fractional second to milliseconds whatever the pattern says, so
//  `.123456` and `.123457` parsed to the same instant and every microsecond difference between two
//  `timestamp(6)` columns read as identical no matter what precision the user asked for. The
//  comparison then scaled a `Double` seconds value by up to 1e9, which leaves Double's
//  exact-integer range and puts the same class of precision loss back into the fixed path.
//

import Foundation
@testable import TablePro
import Testing

struct TimestampValueTests {
    private func value(_ text: String) throws -> TimestampValue {
        try #require(TimestampValue.parse(text), "\(text) should parse as a timestamp")
    }

    // MARK: - Sub-second precision

    @Test
    func microsecondDifferenceIsNotIdenticalAtSixDigits() throws {
        let earlier = try value("2024-01-01 10:00:00.123456")
        let later = try value("2024-01-01 10:00:00.123457")

        #expect(!earlier.equals(later, fractionalDigits: 6))
    }

    @Test
    func microsecondDifferenceIsIdenticalAtThreeDigits() throws {
        let earlier = try value("2024-01-01 10:00:00.123456")
        let later = try value("2024-01-01 10:00:00.123999")

        #expect(earlier.equals(later, fractionalDigits: 3))
    }

    @Test
    func nanosecondDifferenceIsNotIdenticalAtNineDigits() throws {
        let earlier = try value("2024-01-01 10:00:00.123456789")
        let later = try value("2024-01-01 10:00:00.123456790")

        #expect(!earlier.equals(later, fractionalDigits: 9))
        #expect(earlier.equals(later, fractionalDigits: 6))
    }

    @Test
    func wholeSecondsCompareEqualAtEveryPrecision() throws {
        let first = try value("2024-01-01 10:00:00")
        let second = try value("2024-01-01T10:00:00")

        for digits in 0 ... 9 {
            #expect(first.equals(second, fractionalDigits: digits))
        }
    }

    @Test
    func fractionalDigitsAreReadExactlyRatherThanRounded() throws {
        let value = try value("2024-01-01 00:00:00.5")

        #expect(value.nanosecondsSinceEpoch % 1_000_000_000 == 500_000_000)
    }

    @Test
    func moreThanNineFractionalDigitsAreTruncatedNotMisread() throws {
        let value = try value("2024-01-01 00:00:00.1234567891234")

        #expect(value.nanosecondsSinceEpoch % 1_000_000_000 == 123_456_789)
    }

    // MARK: - Offsets

    /// The same instant written at two offsets is one instant, so it is never a difference.
    @Test
    func equivalentInstantsAtDifferentOffsetsCompareEqual() throws {
        let utc = try value("2024-01-01 10:00:00+00:00")
        let offset = try value("2024-01-01 15:30:00+05:30")

        #expect(utc.equals(offset, fractionalDigits: 6))
    }

    @Test
    func offsetWithFractionalSecondsParses() throws {
        let utc = try value("2024-01-01 10:00:00.250000+00:00")

        #expect(utc.nanosecondsSinceEpoch % 1_000_000_000 == 250_000_000)
    }

    // MARK: - Non-timestamps

    @Test
    func shortStringsAndPlainNumbersAreNotTimestamps() {
        for text in ["", "abc", "12", "2024"] {
            #expect(TimestampValue.parse(text) == nil, "\(text) should not parse as a timestamp")
        }
    }

    @Test
    func dateOnlyParses() throws {
        #expect(throws: Never.self) { try value("2024-01-01") }
    }
}

struct FractionalSecondTests {
    @Test
    func fractionIsSplitOffAndScaledToNanoseconds() {
        let split = FractionalSecond.split(from: "2024-01-01 10:00:00.123456")

        #expect(split.withoutFraction == "2024-01-01 10:00:00")
        #expect(split.nanoseconds == 123_456_000)
    }

    /// A `+05:30` offset holds a colon, not a dot, so it must survive untouched.
    @Test
    func offsetSurvivesTheSplit() {
        let split = FractionalSecond.split(from: "2024-01-01 10:00:00.5+05:30")

        #expect(split.withoutFraction == "2024-01-01 10:00:00+05:30")
        #expect(split.nanoseconds == 500_000_000)
    }

    @Test
    func textWithNoFractionIsUnchanged() {
        let split = FractionalSecond.split(from: "2024-01-01 10:00:00")

        #expect(split.withoutFraction == "2024-01-01 10:00:00")
        #expect(split.nanoseconds == 0)
    }
}

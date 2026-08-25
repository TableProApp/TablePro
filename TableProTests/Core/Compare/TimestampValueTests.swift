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

@testable import TablePro
import XCTest

final class TimestampValueTests: XCTestCase {
    private func value(_ text: String) throws -> TimestampValue {
        try XCTUnwrap(TimestampValue.parse(text), "\(text) should parse as a timestamp")
    }

    // MARK: - Sub-second precision

    func testMicrosecondDifferenceIsNotIdenticalAtSixDigits() throws {
        let earlier = try value("2024-01-01 10:00:00.123456")
        let later = try value("2024-01-01 10:00:00.123457")

        XCTAssertFalse(earlier.equals(later, fractionalDigits: 6))
    }

    func testMicrosecondDifferenceIsIdenticalAtThreeDigits() throws {
        let earlier = try value("2024-01-01 10:00:00.123456")
        let later = try value("2024-01-01 10:00:00.123999")

        XCTAssertTrue(earlier.equals(later, fractionalDigits: 3))
    }

    func testNanosecondDifferenceIsNotIdenticalAtNineDigits() throws {
        let earlier = try value("2024-01-01 10:00:00.123456789")
        let later = try value("2024-01-01 10:00:00.123456790")

        XCTAssertFalse(earlier.equals(later, fractionalDigits: 9))
        XCTAssertTrue(earlier.equals(later, fractionalDigits: 6))
    }

    func testWholeSecondsCompareEqualAtEveryPrecision() throws {
        let first = try value("2024-01-01 10:00:00")
        let second = try value("2024-01-01T10:00:00")

        for digits in 0 ... 9 {
            XCTAssertTrue(first.equals(second, fractionalDigits: digits))
        }
    }

    func testFractionalDigitsAreReadExactlyRatherThanRounded() throws {
        let value = try value("2024-01-01 00:00:00.5")

        XCTAssertEqual(value.nanosecondsSinceEpoch % 1_000_000_000, 500_000_000)
    }

    func testMoreThanNineFractionalDigitsAreTruncatedNotMisread() throws {
        let value = try value("2024-01-01 00:00:00.1234567891234")

        XCTAssertEqual(value.nanosecondsSinceEpoch % 1_000_000_000, 123_456_789)
    }

    // MARK: - Offsets

    /// The same instant written at two offsets is one instant, so it is never a difference.
    func testEquivalentInstantsAtDifferentOffsetsCompareEqual() throws {
        let utc = try value("2024-01-01 10:00:00+00:00")
        let offset = try value("2024-01-01 15:30:00+05:30")

        XCTAssertTrue(utc.equals(offset, fractionalDigits: 6))
    }

    func testOffsetWithFractionalSecondsParses() throws {
        let utc = try value("2024-01-01 10:00:00.250000+00:00")

        XCTAssertEqual(utc.nanosecondsSinceEpoch % 1_000_000_000, 250_000_000)
    }

    // MARK: - Non-timestamps

    func testShortStringsAndPlainNumbersAreNotTimestamps() {
        for text in ["", "abc", "12", "2024"] {
            XCTAssertNil(TimestampValue.parse(text), "\(text) should not parse as a timestamp")
        }
    }

    func testDateOnlyParses() throws {
        XCTAssertNoThrow(try value("2024-01-01"))
    }
}

final class FractionalSecondTests: XCTestCase {
    func testFractionIsSplitOffAndScaledToNanoseconds() {
        let split = FractionalSecond.split(from: "2024-01-01 10:00:00.123456")

        XCTAssertEqual(split.withoutFraction, "2024-01-01 10:00:00")
        XCTAssertEqual(split.nanoseconds, 123_456_000)
    }

    /// A `+05:30` offset holds a colon, not a dot, so it must survive untouched.
    func testOffsetSurvivesTheSplit() {
        let split = FractionalSecond.split(from: "2024-01-01 10:00:00.5+05:30")

        XCTAssertEqual(split.withoutFraction, "2024-01-01 10:00:00+05:30")
        XCTAssertEqual(split.nanoseconds, 500_000_000)
    }

    func testTextWithNoFractionIsUnchanged() {
        let split = FractionalSecond.split(from: "2024-01-01 10:00:00")

        XCTAssertEqual(split.withoutFraction, "2024-01-01 10:00:00")
        XCTAssertEqual(split.nanoseconds, 0)
    }
}

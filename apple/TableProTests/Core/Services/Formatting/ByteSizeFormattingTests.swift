import Foundation
@testable import TablePro
import Testing

struct ByteSizeFormattingTests {
    @Test("Sizes carry a unit and scale up")
    func sizesScale() {
        #expect(ByteSizeFormatting.string(bytes: Int64(512)).contains("512"))
        #expect(!ByteSizeFormatting.string(bytes: Int64(5_000_000)).isEmpty)
        #expect(ByteSizeFormatting.string(bytes: Int64(512)) != ByteSizeFormatting.string(bytes: Int64(5_000_000)))
    }

    @Test("Every overload agrees for the same value")
    func overloadsAgree() {
        let expected = ByteSizeFormatting.string(bytes: Int64(1_048_576))
        #expect(ByteSizeFormatting.string(bytes: 1_048_576) == expected)
        #expect(ByteSizeFormatting.string(bytes: UInt64(1_048_576)) == expected)
        #expect(ByteSizeFormatting.string(byteString: "1048576") == expected)
    }

    @Test("A value the server did not report as a number passes through untouched")
    func nonNumericStringPassesThrough() {
        #expect(ByteSizeFormatting.string(byteString: "unknown") == "unknown")
    }

    @Test("A rate is the size for that many bytes, per second")
    func ratesRenderPerSecond() {
        let rate = ByteSizeFormatting.string(bytesPerSecond: 145_408)

        #expect(rate.hasPrefix(ByteSizeFormatting.string(bytes: Int64(145_408))))
        #expect(rate.hasSuffix("/s"))
    }

    @Test("A fractional rate rounds to whole bytes")
    func ratesRound() {
        #expect(ByteSizeFormatting.string(bytesPerSecond: 511.6) == ByteSizeFormatting.string(bytesPerSecond: 512))
    }

    /// A sampler dividing by an interval it measured can produce these, and `Int64(_:)` traps on
    /// every one of them.
    @Test("A rate that is not a finite non-negative number renders as nothing")
    func unrepresentableRatesRenderEmpty() {
        #expect(ByteSizeFormatting.string(bytesPerSecond: .infinity).isEmpty)
        #expect(ByteSizeFormatting.string(bytesPerSecond: .nan).isEmpty)
        #expect(ByteSizeFormatting.string(bytesPerSecond: -1).isEmpty)
        #expect(ByteSizeFormatting.string(bytesPerSecond: Double(Int64.max)).isEmpty)
    }

    @Test("Durations grow units as they get longer")
    func durationsGrowUnits() {
        let seconds = DurationFormatting.string(seconds: 5)
        let minutes = DurationFormatting.string(seconds: 300)
        let hours = DurationFormatting.string(seconds: 7_200)
        #expect(seconds != minutes)
        #expect(minutes != hours)
        #expect(!hours.isEmpty)
    }

    @Test("A slow log duration under a second keeps its unit instead of reading 0s")
    func subSecondDurationsKeepTheirUnit() {
        let zero = DurationFormatting.string(seconds: 0)
        #expect(DurationFormatting.string(microseconds: 626) != zero)
        #expect(DurationFormatting.string(microseconds: 12_345) != zero)
        #expect(DurationFormatting.string(microseconds: 12_345) != DurationFormatting.string(microseconds: 626))
        #expect(DurationFormatting.string(microseconds: 2_000_000) == DurationFormatting.string(seconds: 2))
        #expect(DurationFormatting.string(microseconds: 999_600) == DurationFormatting.string(seconds: 1))
        #expect(!DurationFormatting.string(microseconds: -5).contains("-"))
    }

    @Test("A negative uptime does not render as a negative duration")
    func negativeDurationIsClamped() {
        #expect(!DurationFormatting.string(seconds: -10).contains("-"))
    }

    @Test("Microseconds round half up to whole milliseconds", arguments: [
        (499, Duration.microseconds(499)), (500, .milliseconds(1)), (1_499, .milliseconds(1)),
        (1_500, .milliseconds(2)), (12_345, .milliseconds(12)), (999_499, .milliseconds(999)),
    ] as [(Int, Duration)])
    func microsecondsRoundToMilliseconds(microseconds: Int, expected: Duration) {
        let unit: Set<Duration.UnitsFormatStyle.Unit> = expected < .milliseconds(1) ? [.microseconds] : [.milliseconds]
        #expect(DurationFormatting.string(microseconds: microseconds) == expected.formatted(.units(allowed: unit, width: .narrow)))
    }

    @Test("A slow log duration at the top of the integer range formats instead of crashing", arguments: [
        Int.max, Int.max - 499, Int.max - 500,
    ])
    func microsecondsNearIntMax(microseconds: Int) {
        #expect(DurationFormatting.string(microseconds: microseconds) == DurationFormatting.string(seconds: Double(microseconds) / 1_000_000))
    }

    @Test("Fractional seconds round to the nearest second")
    func fractionalSecondsRound() {
        #expect(DurationFormatting.string(seconds: 89.4) == DurationFormatting.string(seconds: 89))
        #expect(DurationFormatting.string(seconds: 89.6) == DurationFormatting.string(seconds: 90))
        #expect(DurationFormatting.string(seconds: 7_199.7) == DurationFormatting.string(seconds: 7_200))
    }

    @Test("Seconds that are not a finite number inside Int format instead of crashing", arguments: [
        (Double.nan, 0), (.infinity, .max), (-.infinity, 0), (1e300, .max), (-1e300, 0), (Double(Int.max), .max),
    ] as [(Double, Int)])
    func unrepresentableSeconds(seconds: Double, expected: Int) {
        #expect(DurationFormatting.string(seconds: seconds) == DurationFormatting.string(seconds: expected))
    }

    @Test("Milliseconds format as the same number of microseconds, saturating past the integer range")
    func millisecondsFormat() {
        #expect(DurationFormatting.string(milliseconds: 320) == DurationFormatting.string(microseconds: 320_000))
        #expect(DurationFormatting.string(milliseconds: 0) == DurationFormatting.string(microseconds: 0))
        #expect(DurationFormatting.string(milliseconds: 9_223_372_036_854_776) == DurationFormatting.string(microseconds: .max))
        #expect(DurationFormatting.string(milliseconds: .max) == DurationFormatting.string(microseconds: .max))
        #expect(!DurationFormatting.string(milliseconds: .min).contains("-"))
    }

    @Test("Mebibytes format as bytes, saturating past Int64")
    func mebibytesFormat() {
        #expect(ByteSizeFormatting.string(mebibytes: 136) == ByteSizeFormatting.string(bytes: Int64(136 * 1_048_576)))
        #expect(ByteSizeFormatting.string(mebibytes: 8_796_093_022_208) == ByteSizeFormatting.string(bytes: Int64.max))
        #expect(ByteSizeFormatting.string(mebibytes: .max) == ByteSizeFormatting.string(bytes: Int64.max))
    }

    @Test("A Double converts to Int by truncation, pinned to Int's range, with NaN as zero", arguments: [
        (83.9, 83), (-83.9, -83), (0, 0), (.nan, 0), (.infinity, .max), (-.infinity, .min),
        (1e30, .max), (-1e30, .min), (9.3e18, .max), (Double(Int.max), .max), (Double(Int.min), .min),
    ] as [(Double, Int)])
    func saturatingInt(value: Double, expected: Int) {
        #expect(SaturatingArithmetic.int(value) == expected)
    }

    @Test("A product past the integer range pins to the end its sign points at")
    func saturatingProduct() {
        #expect(SaturatingArithmetic.product(Int64(136), 1_048_576) == 142_606_336)
        #expect(SaturatingArithmetic.product(Int64.max, 2) == .max)
        #expect(SaturatingArithmetic.product(Int64.min, 2) == .min)
        #expect(SaturatingArithmetic.product(Int64.min, -1) == .max)
        #expect(SaturatingArithmetic.product(Int.max / 2, -3) == .min)
    }
}

@MainActor
struct DateDisplayFormattingTests {
    @Test("A fixed pattern renders in the Gregorian calendar whatever the region is")
    func fixedPatternIgnoresRegionCalendar() throws {
        let service = DateFormattingService.shared
        service.updateFormat(.iso8601)
        let rendered = try #require(service.format(dateString: "2025-08-07 14:30:00", columnType: .datetime(rawType: nil)))
        #expect(rendered.hasPrefix("2025"))
    }
}

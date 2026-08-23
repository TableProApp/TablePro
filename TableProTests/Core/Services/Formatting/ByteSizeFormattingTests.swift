import Foundation
@testable import TablePro
import Testing

@Suite("Byte and duration formatting")
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

    @Test("Durations grow units as they get longer")
    func durationsGrowUnits() {
        let seconds = DurationFormatting.string(seconds: 5)
        let minutes = DurationFormatting.string(seconds: 300)
        let hours = DurationFormatting.string(seconds: 7_200)
        #expect(seconds != minutes)
        #expect(minutes != hours)
        #expect(!hours.isEmpty)
    }

    @Test("A negative uptime does not render as a negative duration")
    func negativeDurationIsClamped() {
        #expect(!DurationFormatting.string(seconds: -10).contains("-"))
    }
}

@Suite("Date display formatting")
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

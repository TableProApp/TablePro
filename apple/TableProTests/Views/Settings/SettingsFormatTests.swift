import Foundation
@testable import TablePro
import Testing

struct SettingsFormatTests {
    private static let english = Locale(identifier: "en_US")

    @Test(
        "Durations use whole words",
        arguments: [
            (1, "1 second"),
            (30, "30 seconds"),
            (60, "1 minute"),
            (90, "1 minute, 30 seconds"),
            (300, "5 minutes"),
            (3600, "1 hour"),
        ]
    )
    func durations(seconds: Int, expected: String) {
        #expect(SettingsFormat.duration(seconds: seconds, locale: Self.english) == expected)
    }

    @Test("Ports stay ungrouped where counts are grouped")
    func portsAreUngrouped() {
        let vietnam = Locale(identifier: "en_VN")
        #expect(SettingsFormat.identifier(23508, locale: vietnam) == "23508")
        #expect(SettingsFormat.identifier(23508, locale: Self.english) == "23508")
        #expect(SettingsFormat.count(23508, locale: vietnam) == "23.508")
        #expect(SettingsFormat.count(1000, locale: Self.english) == "1,000")
    }

    @Test(
        "Day spans read as days, and whole years as years",
        arguments: [
            (1, "1 day"),
            (7, "7 days"),
            (30, "30 days"),
            (90, "90 days"),
            (365, "1 year"),
            (730, "2 years"),
        ]
    )
    func daySpans(days: Int, expected: String) {
        #expect(SettingsFormat.days(days, locale: Self.english) == expected)
    }
}

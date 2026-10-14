//
//  FixedFormatDateFormatterLocaleTests.swift
//  TableProTests
//

import Foundation
import Testing

/// A `DateFormatter` with a fixed `dateFormat` resolves `yyyy` against the *user's* calendar, so a
/// machine set to the Buddhist or Japanese calendar writes 2569 or R7 where the format meant 2026.
/// Apple's own guidance is to pin a POSIX locale for every fixed format. These values reach cell
/// text, the clipboard and export files, so this is wrong data rather than a display glitch.
struct FixedFormatDateFormatterLocaleTests {
    @Test("A fixed format under a non-Gregorian calendar needs the POSIX locale to stay Gregorian")
    func posixLocaleKeepsTheGregorianYear() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-18T00:00:00Z"))
        let buddhist = Locale(identifier: "th_TH@calendar=buddhist")

        let unpinned = DateFormatter()
        unpinned.locale = buddhist
        unpinned.timeZone = TimeZone(identifier: "UTC")
        unpinned.dateFormat = "yyyy-MM-dd"

        let pinned = DateFormatter()
        pinned.locale = Locale(identifier: "en_US_POSIX")
        pinned.timeZone = TimeZone(identifier: "UTC")
        pinned.dateFormat = "yyyy-MM-dd"

        #expect(unpinned.string(from: date) != "2026-09-18")
        #expect(pinned.string(from: date) == "2026-09-18")
    }
}

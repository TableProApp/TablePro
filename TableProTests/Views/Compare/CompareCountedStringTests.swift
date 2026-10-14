//
//  CompareCountedStringTests.swift
//  TableProTests
//

import Foundation
import Testing

/// A Compare & Sync window that reads "1 differences" is a defect the compiler cannot see. The
/// string catalog is the only place a plural can live for a string whose whole content is one
/// counted noun: `String(format:)` resolves a plural variation, but only when the catalog declares
/// one. A sentence whose counted noun follows a later argument cannot be reached that way, so those
/// carry their own singular in Swift and are pinned here as separate keys.
struct CompareCountedStringTests {
    @Test("A single change reads as one change")
    func singleChangeReadsAsSingular() {
        #expect(String(format: String(localized: "%d changes"), 1) == "1 change")
        #expect(String(format: String(localized: "%d changes"), 4) == "4 changes")
    }

    @Test("A single byte reads as one byte")
    func singleByteReadsAsSingular() {
        #expect(String(format: String(localized: "%d bytes"), 1) == "1 byte")
        #expect(String(format: String(localized: "%d bytes"), 12) == "12 bytes")
    }

    @Test("A single NULL-keyed row reads in the singular")
    func singleSkippedRowReadsAsSingular() {
        let text = String(
            format: String(
                localized: "%d rows hold NULL in a key column and were left out. Choose a key with no NULLs to compare them."
            ),
            1
        )

        #expect(text.hasPrefix("1 row holds NULL"))
    }

    @Test("A single matching row reads in the singular")
    func singleMatchingRowReadsAsSingular() {
        let text = String(
            format: String(
                localized: "%d rows match. Matching rows are counted, not listed, so a difference is never crowded out of this list."
            ),
            1
        )

        #expect(text.hasPrefix("1 row matches."))
    }

    /// The counted noun follows the second argument in each of these, which a plural variation on
    /// the format string cannot reach, so the view picks the singular sentence instead. They are
    /// keys of their own and have to stay that way.
    @Test("A sentence whose count is not its first argument carries its own singular")
    func restructuredSentencesReadCorrectlyAtOne() {
        #expect(
            String(format: String(localized: "Apply 1 statement to %@?"), "staging") == "Apply 1 statement to staging?"
        )
        #expect(
            String(format: String(localized: "%d of 1 table will be compared."), 1) == "1 of 1 table will be compared."
        )
        #expect(
            String(format: String(localized: "1 statement, %d will run."), 0) == "1 statement, 0 will run."
        )
        #expect(
            String(
                format: String(localized: "1 statement stays out of this run and %@ keeps what it has for it."),
                "staging"
            ) == "1 statement stays out of this run and staging keeps what it has for it."
        )
    }
}

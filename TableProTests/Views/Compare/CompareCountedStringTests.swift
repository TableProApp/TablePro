//
//  CompareCountedStringTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// A Compare & Sync window that reads "1 differences" is a defect the compiler cannot see. The
/// string catalog is the only place a plural can live for a string whose whole content is one
/// counted noun: `String(format:)` resolves a plural variation, but only when the catalog declares
/// one. A sentence whose counted noun follows a later argument cannot be reached that way, so those
/// carry their own singular in Swift and are pinned here as separate keys.
@Suite("Compare counted strings")
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

    @Test("Every Compare plural lives in the catalog rather than in a Swift branch")
    func catalogDeclaresTheComparePlurals() throws {
        for key in Self.pluralKeys {
            let entry = try Self.catalogEntry(key)
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let english = try #require(localizations["en"] as? [String: Any])
            let variations = try #require(english["variations"] as? [String: Any])
            let plural = try #require(variations["plural"] as? [String: Any])

            #expect(plural["one"] != nil, "\(key) declares no singular")
            #expect(plural["other"] != nil, "\(key) declares no plural")
        }
    }

    /// A plural variation rewrites only the source language. Rewriting the English `stringUnit` into
    /// a `%#@substitution@` form instead changes the source every translation is checked against,
    /// which is what leaves `StringCatalogIntegrityTests` reporting five offenders on the one string
    /// that already does it.
    @Test("A Compare plural leaves the English source string alone")
    func pluralsDoNotRewriteTheEnglishSourceString() throws {
        for key in Self.pluralKeys {
            let entry = try Self.catalogEntry(key)
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let english = try #require(localizations["en"] as? [String: Any])

            #expect(english["stringUnit"] == nil, "\(key) rewrote its source string")
            #expect(english["substitutions"] == nil, "\(key) rewrote its source string")
        }
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

    private static let pluralKeys = [
        "%d changes",
        "%d bytes",
        "%d rows hold NULL in a key column and were left out. Choose a key with no NULLs to compare them.",
        "%d rows match. Matching rows are counted, not listed, so a difference is never crowded out of this list."
    ]

    private static func catalogEntry(_ key: String) throws -> [String: Any] {
        let url = try repoRoot().appendingPathComponent("TablePro/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        return try #require(strings[key] as? [String: Any])
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CatalogError.repoRootNotFound
    }

    private enum CatalogError: Error {
        case repoRootNotFound
    }
}

//
//  FrenchCountedStringsTests.swift
//  TableProTests
//

import Foundation
import Testing

/// A translation may not carry `^[noun](inflect: true)`, so French agrees a noun with its count through
/// plural variations in the catalog. These read the compiled `fr.lproj`, which is what the app ships,
/// so a variation that names the wrong argument or drops a category fails here and not in front of a
/// French user.
struct FrenchCountedStringsTests {
    private static let french = Locale(identifier: "fr_FR")

    private static func frenchBundle() throws -> Bundle {
        let url = try #require(Bundle.main.url(forResource: "fr", withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }

    private static func localized(_ value: String.LocalizationValue) throws -> String {
        String(localized: value, bundle: try frenchBundle(), locale: french)
    }

    @Test("A row count agrees with its number, and French counts zero as singular")
    func rowCountAgrees() throws {
        #expect(try Self.localized("^[\(0) row](inflect: true)") == "0 ligne")
        #expect(try Self.localized("^[\(1) row](inflect: true)") == "1 ligne")
        #expect(try Self.localized("^[\(3) row](inflect: true)") == "3 lignes")
    }

    @Test("A range of rows agrees with the total it names")
    func rangeAgreesWithItsTotal() throws {
        #expect(try Self.localized("\(1)-\(1) of ^[\(1) row](inflect: true)") == "1-1 sur 1 ligne")
        #expect(try Self.localized("\(1)-\(50) of ^[\(120) row](inflect: true)") == "1-50 sur 120 lignes")
        /// An interpolated count is formatted for the locale, so French groups thousands with U+202F.
        #expect(try Self.localized("\(1)-\(50) of ~^[\(9_000) row](inflect: true)") == "1-50 sur ~9\u{202F}000 lignes")
    }

    @Test("A statement count agrees, verb included")
    func statementCountAgrees() throws {
        #expect(try Self.localized("Executed ^[\(1) statement](inflect: true)") == "1 instruction exécutée")
        #expect(try Self.localized("Executed ^[\(4) statement](inflect: true)") == "4 instructions exécutées")
    }

    @Test("A count the source varies by plural varies in French too")
    func sourcePluralVariesInFrench() throws {
        let format = String(localized: "%d changes", bundle: try Self.frenchBundle(), locale: Self.french)

        #expect(String(format: format, 1) == "1 modification")
        #expect(String(format: format, 2) == "2 modifications")
    }
}

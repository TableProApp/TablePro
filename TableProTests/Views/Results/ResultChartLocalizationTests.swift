//
//  ResultChartLocalizationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// A count that reads "with 1 points" is a defect the compiler cannot see, and the string catalog
/// is the only place the plural can live: `String(format:)` resolves a plural variation, but only
/// when the catalog declares one.
@Suite("Result chart localization")
struct ResultChartLocalizationTests {
    @Test("The chart accessibility summary declares a plural for its point count")
    func accessibilitySummaryHasPluralVariations() throws {
        let entry = try catalogEntry("%1$@ chart of %2$@ by %3$@ with %4$d points")
        let english = try #require(entry["localizations"] as? [String: Any])["en"] as? [String: Any]
        let substitutions = try #require(english?["substitutions"] as? [String: Any])
        let points = try #require(substitutions["points"] as? [String: Any])

        #expect(points["argNum"] as? Int == 4)
        #expect(points["formatSpecifier"] as? String == "d")

        let variations = try #require(points["variations"] as? [String: Any])
        let plural = try #require(variations["plural"] as? [String: Any])
        #expect(plural["one"] != nil)
        #expect(plural["other"] != nil)
    }

    @Test("A single point reads as one point")
    func singlePointReadsAsSingular() {
        let summary = String(
            format: String(localized: "%1$@ chart of %2$@ by %3$@ with %4$d points"),
            "Bar",
            "Revenue",
            "Month",
            1
        )

        #expect(summary.hasSuffix("with 1 point"))
    }

    @Test("Several points read as plural")
    func severalPointsReadAsPlural() {
        let summary = String(
            format: String(localized: "%1$@ chart of %2$@ by %3$@ with %4$d points"),
            "Bar",
            "Revenue",
            "Month",
            4
        )

        #expect(summary.hasSuffix("with 4 points"))
    }

    private func catalogEntry(_ key: String) throws -> [String: Any] {
        let url = try Self.repoRoot()
            .appendingPathComponent("TablePro/Resources/Localizable.xcstrings")
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

//
//  QueryPlanValueFormatterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Query plan value formatting")
struct QueryPlanValueFormatterTests {
    /// A metric rendered with `String(describing:)` reaches the user as `52000000.0`, unlocalized
    /// and ungrouped, directly under a summary that spells the same number `52,000,000`.
    @Test("A large cost is grouped, not printed as a Swift Double")
    func largeCostIsGrouped() {
        let rendered = QueryPlanValueFormatter.string(.number(52_000_000), unit: .cost)

        #expect(!rendered.contains("e+"))
        #expect(!rendered.hasSuffix(".0"))
        #expect(rendered.contains(52_000_000.formatted(.number.precision(.fractionLength(0)))))
    }

    @Test("A count carries no fraction")
    func countHasNoFraction() {
        #expect(QueryPlanValueFormatter.string(.number(1_234), unit: .count)
            == 1_234.0.formatted(.number.precision(.fractionLength(0))))
    }

    @Test("A duration renders as a measurement rather than a bare number")
    func durationRendersAsMeasurement() {
        let rendered = QueryPlanValueFormatter.string(.number(1.2345), unit: .milliseconds)
        #expect(rendered.contains("ms"))
    }

    @Test("An absent value is not shown as zero")
    func absentValueIsNotZero() {
        #expect(QueryPlanValueFormatter.string(nil, unit: .count) == QueryPlanValueFormatter.absent)
    }

    @Test("A property value is shown as the database spelled it")
    func propertyValueIsVerbatim() {
        #expect(QueryPlanValueFormatter.string(.text("Hash Right Join"), unit: nil) == "Hash Right Join")
    }

    @Test("A change carries a sign and a percentage")
    func changeCarriesSignAndPercentage() throws {
        let change = QueryPlanFieldChange(
            field: .summary(.totalCost),
            before: .number(100),
            after: .number(150)
        )
        let rendered = try #require(QueryPlanValueFormatter.change(change))

        #expect(rendered.hasPrefix("+"))
        #expect(rendered.contains("%"))
    }

    @Test("An unchanged value has no change text")
    func unchangedValueHasNoChangeText() {
        let change = QueryPlanFieldChange(
            field: .summary(.totalCost),
            before: .number(100),
            after: .number(100)
        )
        #expect(QueryPlanValueFormatter.change(change) == nil)
    }

    /// Percent needs a baseline to be a percentage of, and everything is infinitely larger than
    /// nothing.
    @Test("A change from zero reports the difference without a percentage")
    func changeFromZeroHasNoPercentage() throws {
        let change = QueryPlanFieldChange(
            field: .summary(.totalCost),
            before: .number(0),
            after: .number(10)
        )
        let rendered = try #require(QueryPlanValueFormatter.change(change))
        #expect(!rendered.contains("%"))
    }

    @Test("A text value that changed says so rather than inventing a delta")
    func textChangeHasNoDelta() {
        let change = QueryPlanFieldChange(
            field: .property("Join Type"),
            before: .text("Inner"),
            after: .text("Left")
        )
        #expect(QueryPlanValueFormatter.change(change) == String(localized: "Changed"))
    }
}

@Suite("EXPLAIN preamble normalization")
struct SQLPreambleNormalizerTests {
    @Test("Case and spacing do not change the preamble")
    func normalizesCaseAndSpacing() {
        #expect(SQLPreambleNormalizer.normalize("  explain  format = tree ")
            == SQLPreambleNormalizer.normalize("EXPLAIN FORMAT=TREE"))
    }

    @Test("Punctuation is kept, because it is part of the option")
    func keepsPunctuation() {
        #expect(SQLPreambleNormalizer.normalize("EXPLAIN (ANALYZE, BUFFERS)")
            == "EXPLAIN ( ANALYZE , BUFFERS )")
    }

    @Test("Different options stay different")
    func differentOptionsStayDifferent() {
        #expect(SQLPreambleNormalizer.normalize("EXPLAIN ANALYZE")
            != SQLPreambleNormalizer.normalize("EXPLAIN"))
    }
}

@Suite("Plan variant keys")
struct QueryPlanVariantKeyTests {
    @Test("A declared variant and a typed statement never collide")
    func declaredAndTypedNeverCollide() {
        #expect(QueryPlanVariantKey.declared("explain") != QueryPlanVariantKey.typed(preamble: "explain"))
    }

    @Test("A key is bounded so a pathological preamble cannot grow the index entry")
    func keyIsBounded() {
        let key = QueryPlanVariantKey.typed(preamble: String(repeating: "OPTION ", count: 500))
        #expect(key.rawValue.count == QueryPlanVariantKey.maximumLength)
    }

    /// The stored key stays readable, which is what makes it debuggable in a database browser and
    /// showable in the baseline picker.
    @Test("A key shows the options rather than a digest")
    func keyIsReadable() {
        #expect(QueryPlanVariantKey.typed(preamble: "EXPLAIN ANALYZE").displayName == "EXPLAIN ANALYZE")
        #expect(QueryPlanVariantKey.declared("explain-json").displayName == "explain-json")
    }
}

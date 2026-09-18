//
//  ExplainVariantFormatTests.swift
//  TableProTests
//
//  Guards the additive contract of ExplainVariant.format: a plugin built against the older
//  three-argument initializer must keep compiling and must report the documented default.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Explain Variant Format")
struct ExplainVariantFormatTests {
    @Test("The legacy initializer still compiles and defaults to plain text")
    func legacyInitializerDefaultsToPlainText() {
        let variant = ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN")

        #expect(variant.id == "explain")
        #expect(variant.label == "EXPLAIN")
        #expect(variant.sqlPrefix == "EXPLAIN")
        #expect(variant.format == .plainText)
    }

    @Test("The format initializer round-trips an explicit format")
    func formatInitializerRoundTrips() {
        let variant = ExplainVariant(
            id: "explain-json",
            label: "EXPLAIN (JSON)",
            sqlPrefix: "EXPLAIN FORMAT=JSON",
            format: .mysqlComposite
        )

        #expect(variant.format == .mysqlComposite)
        #expect(variant.sqlPrefix == "EXPLAIN FORMAT=JSON")
    }

    @Test("Both initializers agree on the fields they share")
    func initializersAgreeOnSharedFields() {
        let legacy = ExplainVariant(id: "plan", label: "Query Plan", sqlPrefix: "EXPLAIN QUERY PLAN")
        let tagged = ExplainVariant(
            id: "plan",
            label: "Query Plan",
            sqlPrefix: "EXPLAIN QUERY PLAN",
            format: .sqliteQueryPlan
        )

        #expect(legacy.id == tagged.id)
        #expect(legacy.label == tagged.label)
        #expect(legacy.sqlPrefix == tagged.sqlPrefix)
        #expect(legacy.format != tagged.format)
    }

    @Test("An unknown format a future plugin names round-trips without a PluginKit change")
    func unknownFormatRoundTrips() {
        let future = ExplainPlanFormat(rawValue: "someFutureEngine")
        let variant = ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: future)

        #expect(variant.format.rawValue == "someFutureEngine")
        #expect(variant.format != .plainText)
    }
}

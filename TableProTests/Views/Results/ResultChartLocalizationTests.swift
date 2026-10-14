//
//  ResultChartLocalizationTests.swift
//  TableProTests
//

import Foundation
import Testing

/// A count that reads "with 1 points" is a defect the compiler cannot see: `String(format:)`
/// resolves a plural variation only when the catalog declares one.
struct ResultChartLocalizationTests {
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
}

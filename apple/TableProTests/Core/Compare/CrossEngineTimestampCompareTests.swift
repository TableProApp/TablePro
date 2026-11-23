//
//  CrossEngineTimestampCompareTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

// A PostgreSQL server on Asia/Bangkok renders a timestamptz at +07. The copier and the sync write its wall clock into a
// MySQL datetime, and the comparator read that datetime as UTC, so every row stayed an update after every Apply.
struct CrossEngineTimestampCompareTests {
    private let comparator = CellValueComparator(options: .default)

    private func written(_ value: PluginCellValue) -> PluginCellValue {
        CrossEngineValueCoercer.coerce(
            value,
            pair: CrossEngineValueCoercer.ColumnPair(
                source: SQLTypeParser.parse("timestamptz", family: .postgres).kind,
                target: SQLTypeParser.parse("datetime", family: .mysql).kind
            ),
            from: .postgres,
            to: .mysql
        )
    }

    @Test
    func aZonedSourceAndTheWallClockTheCopyWroteCompareEqual() {
        let source = PluginCellValue.text("2024-01-01 10:00:00+07")
        let target = written(source)

        #expect(target == .text("2024-01-01 10:00:00"))
        #expect(comparator.compare(source, target, as: .temporal).isEqual)
    }

    @Test
    func aNaiveSourceAndTheZonedValueItReadsBackAsCompareEqual() {
        let outcome = comparator.compare(
            .text("2024-01-01 10:00:00.250000"),
            .text("2024-01-01 10:00:00.25+07:00"),
            as: .temporal
        )

        #expect(outcome.isEqual)
        #expect(outcome.rule == .timestampPrecision)
    }

    @Test
    func anotherWallClockAgainstAZonedValueIsADifference() {
        #expect(!comparator.compare(.text("2024-01-01 10:00:00+07"), .text("2024-01-01 03:00:00"), as: .temporal).isEqual)
    }

    @Test
    func twoZonedValuesStillCompareAsInstants() {
        #expect(comparator.compare(.text("2024-01-01 10:00:00+07"), .text("2024-01-01 03:00:00+00:00"), as: .temporal).isEqual)
        #expect(!comparator.compare(.text("2024-01-01 10:00:00+07"), .text("2024-01-01 10:00:00+00:00"), as: .temporal).isEqual)
    }

    @Test
    func anUndeclaredColumnFollowsTheSameRule() {
        #expect(comparator.compare(.text("2024-01-01 10:00:00+07"), .text("2024-01-01 10:00:00"), as: .unknown).isEqual)
    }
}

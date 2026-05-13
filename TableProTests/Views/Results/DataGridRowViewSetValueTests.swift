//
//  DataGridRowViewSetValueTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DataGridRowView Set Value presets")
@MainActor
struct DataGridRowViewSetValueTests {
    @Test("date column offers CURRENT_DATE only")
    func dateColumnOffersCurrentDate() {
        let presets = DataGridRowView.dateValueFunctions(for: .date(rawType: "DATE"))
        #expect(presets == ["CURRENT_DATE"])
    }

    @Test("datetime column offers NOW and CURRENT_TIMESTAMP")
    func datetimeColumnOffersNowAndTimestamp() {
        let presets = DataGridRowView.dateValueFunctions(for: .datetime(rawType: "DATETIME"))
        #expect(presets == ["NOW()", "CURRENT_TIMESTAMP"])
    }

    @Test("timestamp column offers NOW and CURRENT_TIMESTAMP")
    func timestampColumnOffersNowAndTimestamp() {
        let presets = DataGridRowView.dateValueFunctions(for: .timestamp(rawType: "TIMESTAMP"))
        #expect(presets == ["NOW()", "CURRENT_TIMESTAMP"])
    }

    @Test("TIME column offers CURRENT_TIME only")
    func timeColumnOffersCurrentTime() {
        let presets = DataGridRowView.dateValueFunctions(for: .timestamp(rawType: "TIME"))
        #expect(presets == ["CURRENT_TIME"])
    }

    @Test("TIMETZ column offers CURRENT_TIME only")
    func timetzColumnOffersCurrentTime() {
        let presets = DataGridRowView.dateValueFunctions(for: .timestamp(rawType: "TIMETZ"))
        #expect(presets == ["CURRENT_TIME"])
    }

    @Test("non-date column returns empty list")
    func textColumnReturnsEmpty() {
        let presets = DataGridRowView.dateValueFunctions(for: .text(rawType: "VARCHAR(255)"))
        #expect(presets.isEmpty)
    }

    @Test("all presets are recognized temporal functions")
    func allPresetsRoundTripThroughTemporalDetector() {
        let cases: [ColumnType] = [
            .date(rawType: "DATE"),
            .timestamp(rawType: "TIMESTAMP"),
            .datetime(rawType: "DATETIME"),
            .timestamp(rawType: "TIME"),
        ]
        for columnType in cases {
            for preset in DataGridRowView.dateValueFunctions(for: columnType) {
                #expect(
                    SQLEscaping.isTemporalFunction(preset),
                    "preset \(preset) for \(columnType) must be recognized by SQLEscaping"
                )
            }
        }
    }
}

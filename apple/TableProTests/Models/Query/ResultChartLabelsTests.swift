//
//  ResultChartLabelsTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct ResultChartLabelsTests {
    @Test("Duplicates are numbered and single labels are left alone")
    func numbersDuplicates() {
        #expect(ResultChartLabels.unique(["value", "group", "value"]) == ["value (1)", "group", "value (2)"])
    }

    @Test("A number already taken by a real value is skipped")
    func skipsTakenNumbers() {
        let labels = ResultChartLabels.unique(["No value", "No value (1)", "No value"])

        #expect(labels == ["No value (2)", "No value (1)", "No value (3)"])
        #expect(Set(labels).count == labels.count)
    }
}

//
//  MariaDBResultColumnTypeTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct MariaDBResultColumnTypeTests {
    /// Every DECIMAL result column arrives as protocol type 246, which the MySQL plugin names `DECIMAL`
    /// (MySQLDriverTests pins that). Named after the protocol constant, it fell through the classifier to
    /// text, so charts, sorting and JSON copy treated the numbers as strings.
    @Test("A DECIMAL result column classifies as a number")
    func decimalResultColumnIsNumeric() {
        guard case .decimal = ColumnTypeClassifier().classify(rawTypeName: "DECIMAL") else {
            Issue.record("DECIMAL must classify as decimal")
            return
        }
    }
}

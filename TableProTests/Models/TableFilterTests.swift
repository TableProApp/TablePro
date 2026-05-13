//
//  TableFilterTests.swift
//  TableProTests
//
//  Created on 2026-02-17.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Table Filter")
struct TableFilterTests {

    @Test("Requires value returns false for isNull")
    func requiresValueIsNull() {
        #expect(FilterOperator.isNull.requiresValue == false)
    }

    @Test("Requires value returns false for isNotNull")
    func requiresValueIsNotNull() {
        #expect(FilterOperator.isNotNull.requiresValue == false)
    }

    @Test("Requires value returns false for isEmpty")
    func requiresValueIsEmpty() {
        #expect(FilterOperator.isEmpty.requiresValue == false)
    }

    @Test("Requires value returns false for isNotEmpty")
    func requiresValueIsNotEmpty() {
        #expect(FilterOperator.isNotEmpty.requiresValue == false)
    }

    @Test("Requires value returns true for equal")
    func requiresValueEqual() {
        #expect(FilterOperator.equal.requiresValue == true)
    }

    @Test("Requires value returns true for contains")
    func requiresValueContains() {
        #expect(FilterOperator.contains.requiresValue == true)
    }

    @Test("Requires second value only for between")
    func requiresSecondValueBetween() {
        #expect(FilterOperator.between.requiresSecondValue == true)
    }

    @Test("Requires second value returns false for non-between operators")
    func requiresSecondValueOthers() {
        #expect(FilterOperator.equal.requiresSecondValue == false)
        #expect(FilterOperator.greaterThan.requiresSecondValue == false)
        #expect(FilterOperator.isNull.requiresSecondValue == false)
    }

    @Test("Valid filter with all required fields")
    func validFilter() {
        let filter = TableFilter(
            columnName: "name",
            filterOperator: .equal,
            value: "test",
            secondValue: nil,
            rawSQL: nil
        )
        #expect(filter.isValid == true)
        #expect(filter.validationError == nil)
    }

    @Test("Invalid filter with empty column name")
    func invalidFilterEmptyColumn() {
        let filter = TableFilter(
            columnName: "",
            filterOperator: .equal,
            value: "test",
            secondValue: nil,
            rawSQL: nil
        )
        #expect(filter.isValid == false)
        #expect(filter.validationError == String(localized: "Please select a column"))
    }

    @Test("Invalid filter with missing required value")
    func invalidFilterMissingValue() {
        let filter = TableFilter(
            columnName: "name",
            filterOperator: .equal,
            value: "",
            secondValue: nil,
            rawSQL: nil
        )
        #expect(filter.isValid == false)
        #expect(filter.validationError == String(localized: "Value is required"))
    }

    @Test("Valid filter with isNull and no value")
    func validFilterIsNull() {
        let filter = TableFilter(
            columnName: "name",
            filterOperator: .isNull,
            value: "",
            secondValue: nil,
            rawSQL: nil
        )
        #expect(filter.isValid == true)
        #expect(filter.validationError == nil)
    }

    @Test("Valid filter with between and second value")
    func validFilterBetween() {
        let filter = TableFilter(
            columnName: "age",
            filterOperator: .between,
            value: "10",
            secondValue: "20",
            rawSQL: nil
        )
        #expect(filter.isValid == true)
        #expect(filter.validationError == nil)
    }

    @Test("Invalid filter with between but missing second value")
    func invalidFilterBetweenMissingSecondValue() {
        let filter = TableFilter(
            columnName: "age",
            filterOperator: .between,
            value: "10",
            secondValue: nil,
            rawSQL: nil
        )
        #expect(filter.isValid == false)
        #expect(filter.validationError == String(localized: "Second value is required for BETWEEN"))
    }

    @Test("Is raw SQL when column name is __RAW__")
    func isRawSQL() {
        let filter = TableFilter(
            columnName: TableFilter.rawSQLColumn,
            filterOperator: .equal,
            value: "",
            secondValue: nil,
            rawSQL: "age > 18"
        )
        #expect(filter.isRawSQL == true)
    }

    @Test("Valid raw SQL filter with rawSQL provided")
    func validRawSQLFilter() {
        let filter = TableFilter(
            columnName: TableFilter.rawSQLColumn,
            filterOperator: .equal,
            value: "",
            secondValue: nil,
            rawSQL: "age > 18"
        )
        #expect(filter.isValid == true)
        #expect(filter.validationError == nil)
    }

    @Test("Invalid raw SQL filter with empty rawSQL")
    func invalidRawSQLFilterEmpty() {
        let filter = TableFilter(
            columnName: TableFilter.rawSQLColumn,
            filterOperator: .equal,
            value: "",
            secondValue: nil,
            rawSQL: ""
        )
        #expect(filter.isValid == false)
        #expect(filter.validationError == String(localized: "Raw SQL cannot be empty"))
    }

    @Test("Invalid raw SQL filter with nil rawSQL")
    func invalidRawSQLFilterNil() {
        let filter = TableFilter(
            columnName: TableFilter.rawSQLColumn,
            filterOperator: .equal,
            value: "",
            secondValue: nil,
            rawSQL: nil
        )
        #expect(filter.isValid == false)
        #expect(filter.validationError == String(localized: "Raw SQL cannot be empty"))
    }
}

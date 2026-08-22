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

    @Test("Plugin tuple forwards raw SQL content for a raw filter")
    func pluginTupleForwardsRawSQL() {
        let filter = TableFilter(
            columnName: TableFilter.rawSQLColumn,
            filterOperator: .equal,
            value: "",
            rawSQL: "name:Widget"
        )
        let pluginFilter = filter.asPluginQueryFilter
        #expect(pluginFilter.column == TableFilter.rawSQLColumn)
        #expect(pluginFilter.value == "name:Widget")
    }

    @Test("Plugin filter uses value for a column filter")
    func pluginFilterUsesValueForColumn() {
        let filter = TableFilter(columnName: "name", filterOperator: .equal, value: "Widget")
        #expect(filter.asPluginQueryFilter.value == "Widget")
    }

    // MARK: - Element Scope

    @Test("Element scope survives an encode and decode round trip")
    func elementScopeRoundTrips() throws {
        let filter = TableFilter(
            columnName: "items.price", filterOperator: .greaterThan, value: "500",
            elementScope: "items"
        )
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(TableFilter.self, from: data)
        #expect(decoded.elementScope == "items")
        #expect(decoded.columnName == "items.price")
    }

    @Test("Element scope is written to the encoded payload, not dropped by CodingKeys")
    func elementScopeIsEncoded() throws {
        let filter = TableFilter(columnName: "items.sku", value: "A100", elementScope: "items")
        let data = try JSONEncoder().encode(filter)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("elementScope"))
    }

    @Test("A filter saved before element scope existed decodes with none")
    func elementScopeDefaultsWhenAbsent() throws {
        let legacy = #"{"columnName":"name","filterOperator":"=","value":"Widget"}"#
        let data = try #require(legacy.data(using: .utf8))
        let decoded = try JSONDecoder().decode(TableFilter.self, from: data)
        #expect(decoded.elementScope == nil)
        #expect(decoded.columnName == "name")
    }

    @Test("A nested path round trips as an ordinary column name")
    func nestedPathRoundTrips() throws {
        let filter = TableFilter(columnName: "customer.country", value: "US")
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(TableFilter.self, from: data)
        #expect(decoded.columnName == "customer.country")
    }

    @Test("Element scope reaches the plugin filter")
    func pluginFilterCarriesElementScope() {
        let filter = TableFilter(columnName: "items.sku", value: "A100", elementScope: "items")
        #expect(filter.asPluginQueryFilter.elementScope == "items")
    }

    @Test("A raw filter never carries an element scope")
    func rawFilterHasNoElementScope() {
        let filter = TableFilter(
            columnName: TableFilter.rawSQLColumn, rawSQL: "{}", elementScope: "items"
        )
        #expect(filter.asPluginQueryFilter.elementScope == nil)
    }

    // MARK: - Between Bounds

    @Test("BETWEEN carries its upper bound separately as well as joined")
    func betweenCarriesSecondValue() {
        let filter = TableFilter(
            columnName: "name", filterOperator: .between, value: "Smith, John", secondValue: "Zed"
        )
        let plugin = filter.asPluginQueryFilter
        #expect(plugin.secondValue == "Zed")
        #expect(plugin.value == "Smith, John,Zed")
    }

    @Test("A non-BETWEEN operator carries no second value")
    func nonBetweenHasNoSecondValue() {
        let filter = TableFilter(columnName: "age", filterOperator: .equal, value: "28")
        #expect(filter.asPluginQueryFilter.secondValue == nil)
    }
}

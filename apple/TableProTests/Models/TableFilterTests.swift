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
            secondValue: nil
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
            secondValue: nil
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
            secondValue: nil
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
            secondValue: nil
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
            secondValue: "20"
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
            secondValue: nil
        )
        #expect(filter.isValid == false)
        #expect(filter.validationError == String(localized: "Second value is required for BETWEEN"))
    }

    @Test("A raw condition is a raw row")
    func isRawSQL() {
        let filter = TableFilter.rawCondition("age > 18")
        #expect(filter.isRawSQL == true)
    }

    @Test("Valid raw SQL filter with its condition typed")
    func validRawSQLFilter() {
        let filter = TableFilter.rawCondition("age > 18")
        #expect(filter.isValid == true)
        #expect(filter.validationError == nil)
    }

    @Test("Invalid raw SQL filter with no condition")
    func invalidRawSQLFilterEmpty() {
        let filter = TableFilter.rawCondition("")
        #expect(filter.isValid == false)
        #expect(filter.validationError == String(localized: "Raw SQL cannot be empty"))
    }

    @Test("Invalid raw SQL filter holding only whitespace")
    func invalidRawSQLFilterWhitespace() {
        let filter = TableFilter.rawCondition(" \n\t")
        #expect(filter.isValid == false)
        #expect(filter.validationError == String(localized: "Raw SQL cannot be empty"))
    }

    @Test("Plugin tuple forwards raw SQL content for a raw filter")
    func pluginTupleForwardsRawSQL() {
        let filter = TableFilter.rawCondition("name:Widget")
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
        var filter = TableFilter.rawCondition("{}")
        filter.elementScope = "items"
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

    // MARK: - One Text Per Row

    @Test("A raw condition stays as typed when the row switches to a column, and back")
    func switchingKindKeepsText() {
        let raw = TableFilter.rawCondition("id = 1")

        let column = raw.selectingColumn("name")
        #expect(column.columnName == "name")
        #expect(column.value == "id = 1")

        let back = column.selectingRawCondition()
        #expect(back.isRawSQL)
        #expect(back.value == "id = 1")
    }

    @Test("A value stays as typed when the row moves to another column")
    func switchingColumnKeepsValue() {
        let filter = TableFilter(columnName: "name", filterOperator: .contains, value: "abc")

        let moved = filter.selectingColumn("email")

        #expect(moved.value == "abc")
        #expect(moved.filterOperator == .contains)
    }

    @Test("A column switch drops the element scope, and picking the same column keeps it")
    func switchingColumnClearsScope() {
        let filter = TableFilter(columnName: "items.sku", value: "A1", elementScope: "items")

        #expect(filter.selectingColumn("name").elementScope == nil)
        #expect(filter.selectingColumn("items.sku").elementScope == "items")
    }

    @Test("An operator change returns Match Case to the new operator's usual setting")
    func selectingOperatorResetsCase() {
        var filter = TableFilter(columnName: "name", filterOperator: .contains, value: "ana")
        filter.isCaseSensitive = true

        #expect(filter.selectingOperator(.equal).isCaseSensitive)
        #expect(!filter.selectingOperator(.startsWith).isCaseSensitive)
        #expect(filter.selectingOperator(.contains).isCaseSensitive, "the same operator changes nothing")
    }

    @Test("A duplicate is the same row under a new id")
    func duplicatedCarriesEveryField() {
        var source = TableFilter(
            columnName: "items.price", filterOperator: .between, value: "1", secondValue: "9",
            isEnabled: false, elementScope: "items"
        )
        source.isCaseSensitive = false

        let copy = source.duplicated()

        #expect(copy.id != source.id)
        #expect(copy.isEnabled == source.isEnabled)
        #expect(copy.hasSameCondition(as: source))
        #expect(copy.secondValue == "9")
        #expect(copy.elementScope == "items")
    }

    @Test("Same condition ignores fields the row's operator does not read")
    func sameConditionIgnoresUnreadFields() {
        let cell = TableFilter(columnName: "name", filterOperator: .equal, value: "bob")

        var leftBetween = TableFilter(columnName: "name", filterOperator: .equal, value: "bob", secondValue: "9")
        #expect(leftBetween.hasSameCondition(as: cell), "the upper bound kept for BETWEEN selects nothing")

        leftBetween.filterOperator = .isNull
        let nullCell = TableFilter(columnName: "name", filterOperator: .isNull)
        #expect(leftBetween.hasSameCondition(as: nullCell), "IS NULL reads no value")

        var greater = TableFilter(columnName: "age", filterOperator: .greaterThan, value: "3")
        greater.isCaseSensitive = false
        #expect(greater.hasSameCondition(as: TableFilter(columnName: "age", filterOperator: .greaterThan, value: "3")))

        let raw = TableFilter.rawCondition("id > 1", filterOperator: .contains)
        #expect(raw.hasSameCondition(as: TableFilter.rawCondition("id > 1")))
    }

    @Test("Same condition still tells apart what the row does read")
    func sameConditionComparesReadFields() {
        let cell = TableFilter(columnName: "name", filterOperator: .equal, value: "bob")

        #expect(!TableFilter(columnName: "name", filterOperator: .equal, value: "ann").hasSameCondition(as: cell))
        #expect(!TableFilter(columnName: "name", filterOperator: .notEqual, value: "bob").hasSameCondition(as: cell))
        var caseless = cell
        caseless.isCaseSensitive = false
        #expect(!caseless.hasSameCondition(as: cell))
        let between = TableFilter(columnName: "age", filterOperator: .between, value: "1", secondValue: "9")
        var otherBound = between
        otherBound.secondValue = "8"
        #expect(!otherBound.hasSameCondition(as: between))
    }

    // MARK: - Saved Before One Text

    @Test("A raw row saved by 0.84 reads its condition from rawSQL, not the hidden value")
    func legacyRawRowDecodes() throws {
        let legacy = #"{"columnName":"__RAW__","filterOperator":"=","value":"stale","rawSQL":"id = 1"}"#
        let decoded = try JSONDecoder().decode(TableFilter.self, from: Data(legacy.utf8))

        #expect(decoded.isRawSQL)
        #expect(decoded.value == "id = 1")
        #expect(decoded.isValid)
    }

    @Test("A column row saved by 0.84 keeps its value and drops a hidden raw condition")
    func legacyColumnRowDecodes() throws {
        let legacy = #"{"columnName":"name","filterOperator":"=","value":"Bob","rawSQL":"id = 2"}"#
        let decoded = try JSONDecoder().decode(TableFilter.self, from: Data(legacy.utf8))

        #expect(decoded.value == "Bob")
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        #expect(reencoded?["rawSQL"] == nil)
    }

    @Test("A raw row saved by 0.84 with no condition stays empty, not the value of the column it left")
    func legacyRawRowWithoutRawSQL() throws {
        let legacy = #"{"columnName":"__RAW__","filterOperator":"=","value":"10"}"#
        let decoded = try JSONDecoder().decode(TableFilter.self, from: Data(legacy.utf8))

        #expect(decoded.value.isEmpty)
        #expect(!decoded.isValid)
    }

    @Test("A list holding only separators is incomplete", arguments: [FilterOperator.inList, .notInList])
    func separatorOnlyListIsIncomplete(op: FilterOperator) {
        #expect(!TableFilter(columnName: "id", filterOperator: op, value: " , ,").isValid)
        #expect(TableFilter(columnName: "id", filterOperator: op, value: "1, 2").isValid)
    }

    @Test("A raw row also writes rawSQL, so 0.84 still reads its condition")
    func rawRowEncodesLegacyKey() throws {
        let filter = TableFilter.rawCondition("age > 3")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(filter)) as? [String: Any]

        #expect(object?["rawSQL"] as? String == "age > 3")
        #expect(object?["value"] as? String == "age > 3")

        let decoded = try JSONDecoder().decode(TableFilter.self, from: JSONEncoder().encode(filter))
        #expect(decoded == filter)
    }

    // MARK: - A Real Column Named Like the Raw Row

    @Test("A comparison built from a real column named __RAW__ stays a comparison, saved and restored")
    func sentinelNamedColumnStaysAComparison() throws {
        let payload = "(SELECT bool_and(pg_terminate_backend(pid)) FROM pg_stat_activity)"
        let cell = TableFilter(columnName: TableFilter.rawSQLColumn, value: payload)

        #expect(!cell.isRawSQL)
        #expect(cell.namesRawConditionColumn)
        #expect(!cell.hasSameCondition(as: .rawCondition(payload)))

        let restored = try JSONDecoder().decode(TableFilter.self, from: JSONEncoder().encode(cell))
        #expect(!restored.isRawSQL)
        #expect(restored.value == payload)
    }

    @Test("Picking a column named __RAW__ makes a comparison; picking Raw SQL makes a raw row")
    func pickerKindsStayApart() {
        let filter = TableFilter(columnName: "name", value: "x")

        #expect(!filter.selectingColumn(TableFilter.rawSQLColumn).isRawSQL)
        #expect(filter.selectingRawCondition().isRawSQL)
        #expect(!filter.selectingRawCondition().selectingColumn("name").isRawSQL)
    }
}

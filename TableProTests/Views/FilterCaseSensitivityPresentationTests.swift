//
//  FilterCaseSensitivityPresentationTests.swift
//  TableProTests
//
//  How a filter row presents its case setting (#2048)
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Filter Case Sensitivity Presentation")
struct FilterCaseSensitivityPresentationTests {

    private func presentation(
        _ filterOperator: FilterOperator,
        isCaseSensitive: Bool,
        style: SQLDialectDescriptor.CaseSensitivityStyle
    ) -> FilterCaseSensitivityPresentation {
        FilterCaseSensitivityPresentation(
            filterOperator: filterOperator, isCaseSensitive: isCaseSensitive, style: style
        )
    }

    @Test("Operators with no case dimension hide the control")
    func testOperatorsWithoutCaseDimension() {
        for filterOperator in [FilterOperator.isNull, .isNotNull, .isEmpty, .isNotEmpty, .between, .greaterThan] {
            let result = presentation(filterOperator, isCaseSensitive: true, style: .ilikeOperator)
            #expect(result.showsControl == false)
            #expect(result.isAdjustable == false)
            #expect(result.showsIndicator == false)
        }
    }

    @Test("An engine with ILIKE offers the control")
    func testIlikeEngineIsAdjustable() {
        let result = presentation(.contains, isCaseSensitive: false, style: .ilikeOperator)
        #expect(result.showsControl)
        #expect(result.isAdjustable)
        #expect(result.fixedReason == nil)
    }

    @Test("A collation-driven engine shows the control but explains why it is fixed")
    func testCollationDefinedIsFixed() {
        let result = presentation(.contains, isCaseSensitive: false, style: .collationDefined)
        #expect(result.showsControl)
        #expect(result.isAdjustable == false)
        #expect(result.fixedReason == "Set by the column's collation")
    }

    @Test("An engine that cannot ignore case says so")
    func testUnsupportedIsFixed() {
        let result = presentation(.contains, isCaseSensitive: false, style: .unsupported)
        #expect(result.isAdjustable == false)
        #expect(result.fixedReason == "Not supported by this database")
    }

    @Test("A driver that matches on its own offers the control")
    func testDriverManagedIsAdjustable() {
        #expect(presentation(.contains, isCaseSensitive: true, style: .driverManaged).isAdjustable)
    }

    @Test("The indicator stays off while a row uses its operator's usual setting")
    func testIndicatorHiddenAtDefault() {
        #expect(presentation(.contains, isCaseSensitive: false, style: .ilikeOperator).showsIndicator == false)
        #expect(presentation(.equal, isCaseSensitive: true, style: .ilikeOperator).showsIndicator == false)
    }

    @Test("The indicator appears once a row departs from that setting")
    func testIndicatorShownOnDeviation() {
        #expect(presentation(.contains, isCaseSensitive: true, style: .ilikeOperator).showsIndicator)
        #expect(presentation(.equal, isCaseSensitive: false, style: .ilikeOperator).showsIndicator)
    }

    @Test("A fixed engine never shows the indicator, since the row cannot deviate")
    func testIndicatorHiddenWhenFixed() {
        #expect(presentation(.contains, isCaseSensitive: true, style: .collationDefined).showsIndicator == false)
        #expect(presentation(.contains, isCaseSensitive: true, style: .unsupported).showsIndicator == false)
    }
}

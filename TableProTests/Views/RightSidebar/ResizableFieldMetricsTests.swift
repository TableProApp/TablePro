//
//  ResizableFieldMetricsTests.swift
//  TableProTests
//

import XCTest

@testable import TablePro

final class ResizableFieldMetricsTests: XCTestCase {
    private let range: ClosedRange<Double> = 80...600

    func testResolveAddsDeltaWithinRange() {
        XCTAssertEqual(ResizableFieldMetrics.resolve(base: 120, delta: 40, range: range), 160)
    }

    func testResolveClampsToLowerBound() {
        XCTAssertEqual(ResizableFieldMetrics.resolve(base: 100, delta: -200, range: range), 80)
    }

    func testResolveClampsToUpperBound() {
        XCTAssertEqual(ResizableFieldMetrics.resolve(base: 500, delta: 400, range: range), 600)
    }

    func testResolveNegativeDeltaStaysWithinRange() {
        XCTAssertEqual(ResizableFieldMetrics.resolve(base: 300, delta: -100, range: range), 200)
    }

    func testResolveHonoursExactBounds() {
        XCTAssertEqual(ResizableFieldMetrics.resolve(base: 80, delta: 0, range: range), 80)
        XCTAssertEqual(ResizableFieldMetrics.resolve(base: 600, delta: 0, range: range), 600)
    }

    func testDefaultJsonHeightIsWithinJsonRange() {
        XCTAssertTrue(ResizableFieldMetrics.jsonHeightRange.contains(ResizableFieldMetrics.defaultJsonHeight))
    }
}

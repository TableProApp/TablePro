import SwiftUI
import Testing

@testable import TablePro

struct ResizableFieldMetricsTests {
    private let range: ClosedRange<Double> = 80...600

    @Test func testResolveAddsDeltaWithinRange() {
        #expect(ResizableFieldMetrics.resolve(base: 120, delta: 40, range: range) == 160)
    }

    @Test func testResolveClampsToLowerBound() {
        #expect(ResizableFieldMetrics.resolve(base: 100, delta: -200, range: range) == 80)
    }

    @Test func testResolveClampsToUpperBound() {
        #expect(ResizableFieldMetrics.resolve(base: 500, delta: 400, range: range) == 600)
    }

    @Test func testResolveNegativeDeltaStaysWithinRange() {
        #expect(ResizableFieldMetrics.resolve(base: 300, delta: -100, range: range) == 200)
    }

    @Test func testResolveHonoursExactBounds() {
        #expect(ResizableFieldMetrics.resolve(base: 80, delta: 0, range: range) == 80)
        #expect(ResizableFieldMetrics.resolve(base: 600, delta: 0, range: range) == 600)
    }

    @Test func testDefaultJsonHeightIsWithinJsonRange() {
        #expect(ResizableFieldMetrics.jsonHeightRange.contains(ResizableFieldMetrics.defaultJsonHeight))
    }

    @Test func testDefaultTextHeightIsWithinTextRange() {
        #expect(ResizableFieldMetrics.textHeightRange.contains(ResizableFieldMetrics.defaultTextHeight))
    }

    @Test func testDefaultGeometryHeightIsWithinGeometryRange() {
        #expect(ResizableFieldMetrics.geometryHeightRange.contains(ResizableFieldMetrics.defaultGeometryHeight))
    }

    /// MapKit drops its logo and legal link from a map under 100pt tall.
    @Test func testAMapNeverShrinksUnderTheHeightThatKeepsItsLogo() {
        let mapRange = ResizableFieldMetrics.geometryHeightRange
        #expect(ResizableFieldMetrics.resolve(base: 160, delta: -500, range: mapRange) == 100)
        #expect(ResizableFieldMetrics.resolve(base: 160, delta: 5_000, range: mapRange) == 600)
    }

    /// A text pane dragged to 60 and then shown as a 100pt map: the drag moves it from 100 at once.
    @Test func testABaseBelowTheFloorMovesWithTheFirstPointOfDrag() {
        let mapRange = ResizableFieldMetrics.geometryHeightRange
        #expect(ResizableFieldMetrics.resolve(base: 60, delta: 30, range: mapRange) == 130)
        #expect(ResizableFieldMetrics.resolve(base: 700, delta: -50, range: mapRange) == 550)
    }

    /// Every field of a kind once shared one stored height, so dragging one resized them all.
    @Test func testDraggingOneFieldLeavesTheOthersAtTheirStartingHeight() {
        var resized: [Int: Double] = [:]
        func height(for column: Int) -> Binding<Double> {
            ResizableFieldMetrics.height(
                resized: Binding(get: { resized[column] }, set: { resized[column] = $0 }),
                starting: 120
            )
        }

        height(for: 1).wrappedValue = 300

        #expect(height(for: 1).wrappedValue == 300)
        #expect(height(for: 2).wrappedValue == 120)
    }

    @Test func testTextHeightResolvesWithinItsOwnRange() {
        let textRange = ResizableFieldMetrics.textHeightRange
        #expect(ResizableFieldMetrics.resolve(base: 110, delta: -500, range: textRange) == textRange.lowerBound)
        #expect(ResizableFieldMetrics.resolve(base: 110, delta: 5_000, range: textRange) == textRange.upperBound)
    }
}

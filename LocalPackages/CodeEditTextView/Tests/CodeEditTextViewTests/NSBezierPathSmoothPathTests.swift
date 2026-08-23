import AppKit
import Testing
@testable import CodeEditTextView

@Suite()
struct NSBezierPathSmoothPathTests {
    @Test()
    func returnsNilForFewerThanTwoPoints() {
        #expect(NSBezierPath.smoothPath([], radius: 4) == nil)
        #expect(NSBezierPath.smoothPath([NSPoint(x: 1, y: 1)], radius: 4) == nil)
    }

    @Test()
    func returnsNilWhenTheFirstTwoPointsAreIdentical() {
        let points = [NSPoint(x: 5, y: 5), NSPoint(x: 5, y: 5), NSPoint(x: 20, y: 5)]
        #expect(NSBezierPath.smoothPath(points + [points[0]], radius: 4) == nil)
    }

    @Test()
    func returnsAMeasurablePathForARectangle() throws {
        let corners = [
            NSPoint(x: 0, y: 0),
            NSPoint(x: 0, y: 10),
            NSPoint(x: 10, y: 10),
            NSPoint(x: 10, y: 0)
        ]
        let path = try #require(NSBezierPath.smoothPath(corners + [corners[0]], radius: 4))

        #expect(path.isEmpty == false)
        let bounds = try #require(path.drawableBounds)
        #expect(bounds.width > 0)
        #expect(bounds.height > 0)
    }
}

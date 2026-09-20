import CoreGraphics
@testable import TableProMobile
import Testing

@Suite("Hairline thickness")
struct HairlineThicknessTests {
    @Test("A hairline is one device pixel on every scale a display reports", arguments: [
        (CGFloat(1), CGFloat(1)),
        (CGFloat(2), CGFloat(0.5)),
        (CGFloat(3), CGFloat(1.0 / 3.0)),
    ])
    func scaleBecomesOnePixel(scale: CGFloat, expected: CGFloat) {
        #expect(HairlineThickness.points(forDisplayScale: scale) == expected)
    }

    @Test("A detached view reporting no scale yet gets a usable thickness, never infinity")
    func unspecifiedScaleIsClamped() {
        for scale in [CGFloat(0), -1, 0.5, .nan, .infinity] {
            let thickness = HairlineThickness.points(forDisplayScale: scale)
            #expect(thickness.isFinite)
            #expect(thickness > 0)
        }
    }
}

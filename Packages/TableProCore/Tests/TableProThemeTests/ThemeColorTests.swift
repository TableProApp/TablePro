import Foundation
import TableProTheme
import Testing

struct ThemeColorTests {
    // MARK: - Parsing

    @Test("Six and eight digit colors parse, trimmed, in either case")
    func acceptedForms() throws {
        let opaque = try #require(ThemeColor(hex: "  #ff79c6\n"))
        #expect(opaque == ThemeColor(red: 0xFF, green: 0x79, blue: 0xC6))
        #expect(opaque.hex == "#FF79C6")

        let translucent = try #require(ThemeColor(hex: "#ff79c680"))
        #expect(translucent.alpha == 0x80)
        #expect(translucent.hex == "#FF79C680")
    }

    @Test("Anything other than ASCII #RRGGBB or #RRGGBBAA is refused")
    func refusedForms() {
        let rejected = [
            "#FF79CG",
            "FF0000",
            "#FFF",
            "#FFFF",
            "#FF00000",
            "#FF0000000",
            "",
            "#",
            "system:label",
            "#\u{FF26}\u{FF26}0000",
            "# FF0000",
        ]
        for value in rejected {
            #expect(ThemeColor(hex: value) == nil, "\(value)")
            #expect(throws: ThemeLoadError.invalidColor(value)) { try ThemeColor(validating: value) }
        }
    }

    @Test("An opaque eight digit color has the six digit spelling")
    func canonicalHex() throws {
        #expect(try #require(ThemeColor(hex: "#112233FF")).hex == "#112233")
        #expect(try #require(ThemeColor(hex: "#11223300")).hex == "#11223300")
        #expect(ThemeColor(hex: "#112233FF") == ThemeColor(hex: "#112233"))
    }

    @Test("Equality and hashing are on the components")
    func equalityOnComponents() {
        let lower = ThemeColor(hex: "#abcdef")
        let upper = ThemeColor(hex: "#ABCDEF")
        #expect(lower == upper)
        #expect(Set([lower, upper]).count == 1)
        #expect(ThemeColor(hex: "#ABCDEF") != ThemeColor(hex: "#ABCDEF80"))
    }

    @Test("opaque keeps the color and drops the alpha")
    func opaqueDropsAlpha() throws {
        let color = try #require(ThemeColor(hex: "#28AA3680"))
        #expect(!color.isOpaque)
        #expect(color.opaque == ThemeColor(red: 0x28, green: 0xAA, blue: 0x36))
        #expect(color.opaque.isOpaque)
    }

    // MARK: - Math

    @Test("Source-over compositing")
    func composite() throws {
        let halfRed = try #require(ThemeColor(hex: "#FF000080"))
        #expect(halfRed.composited(over: .white).hex == "#FF7F7F")
        #expect(ThemeColor.black.composited(over: .white) == .black)
        #expect(ThemeColor(red: 9, green: 9, blue: 9, alpha: 0).composited(over: .white) == .white)

        let halfBlack = try #require(ThemeColor(hex: "#00000080"))
        let halfWhite = try #require(ThemeColor(hex: "#FFFFFF80"))
        #expect(halfBlack.composited(over: halfWhite).hex == "#555555C0")
    }

    @Test("Over an opaque base the result is opaque")
    func compositeOverOpaqueIsOpaque() throws {
        let wash = try #require(ThemeColor(hex: "#44475A26"))
        let base = try #require(ThemeColor(hex: "#282A36"))
        #expect(wash.composited(over: base).isOpaque)
    }

    @Test("A mix moves each component and keeps the alpha")
    func mix() throws {
        #expect(ThemeColor.black.mixed(with: .white, fraction: 0.5).hex == "#808080")
        #expect(ThemeColor.black.mixed(with: .white, fraction: 0) == .black)
        #expect(ThemeColor.black.mixed(with: .white, fraction: 1) == .white)
        #expect(ThemeColor.black.mixed(with: .white, fraction: 2) == .white)

        let translucent = try #require(ThemeColor(hex: "#20406080"))
        #expect(translucent.mixed(with: .white, fraction: 0.25).hex == "#58708880")
    }

    @Test("Relative luminance matches WCAG")
    func luminance() throws {
        #expect(ThemeColor.black.relativeLuminance == 0)
        #expect(abs(ThemeColor.white.relativeLuminance - 1) < 1e-9)
        let grey = try #require(ThemeColor(hex: "#767676"))
        #expect(abs(grey.relativeLuminance - 0.1812) < 0.0005)
    }

    @Test("Contrast ratios of known WCAG pairs")
    func contrast() throws {
        #expect(abs(ThemeColor.black.contrastRatio(with: .white) - 21) < 1e-9)
        #expect(ThemeColor.white.contrastRatio(with: .white) == 1)

        let aaGrey = try #require(ThemeColor(hex: "#767676"))
        #expect(abs(aaGrey.contrastRatio(with: .white) - 4.54) < 0.01)
        #expect(aaGrey.contrastRatio(with: .white) == ThemeColor.white.contrastRatio(with: aaGrey))

        let failingGrey = try #require(ThemeColor(hex: "#777777"))
        #expect(failingGrey.contrastRatio(with: .white) < 4.5)

        let aaaGrey = try #require(ThemeColor(hex: "#595959"))
        #expect(abs(aaaGrey.contrastRatio(with: .white) - 7.0) < 0.01)
    }
}

//
//  CSSColorParserTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct CSSColorParserTests {
    /// Channels on the 0 to 255 scale and alpha to three places, so a row reads like the CSS it parses.
    private static func channels(_ input: String) -> [Double]? {
        guard let color = CSSColorParser.parse(input) else { return nil }
        return [
            (color.red * 255).rounded(),
            (color.green * 255).rounded(),
            (color.blue * 255).rounded(),
            (color.alpha * 1_000).rounded() / 1_000
        ]
    }

    private static func expectColors(_ rows: [(input: String, expected: [Double])]) {
        for row in rows {
            #expect(channels(row.input) == row.expected, "\(row.input)")
        }
    }

    private static func expectNoColor(_ inputs: [String]) {
        for input in inputs {
            #expect(CSSColorParser.parse(input) == nil, "\(input.debugDescription)")
        }
    }

    // MARK: - Hex

    @Test("Three, six and eight hex digits are a color, in either case")
    func hexNotations() {
        Self.expectColors([
            ("#f80", [255, 136, 0, 1]),
            ("#FF8800", [255, 136, 0, 1]),
            ("#ff880080", [255, 136, 0, 0.502]),
            ("#00000000", [0, 0, 0, 0]),
            ("#000", [0, 0, 0, 1]),
            ("#fff", [255, 255, 255, 1]),
            ("#abc", [170, 187, 204, 1]),
            ("#ABC", [170, 187, 204, 1]),
            ("#aAbBcC", [170, 187, 204, 1])
        ])
    }

    @Test("A three digit color doubles each digit, and equals the rgb() spelling exactly")
    func shortHexDoublesEachDigit() {
        let expected = RGBAColor(red: 1, green: 136.0 / 255, blue: 0, alpha: 1)
        #expect(CSSColorParser.parse("#f80") == expected)
        #expect(CSSColorParser.parse("#ff8800") == expected)
        #expect(CSSColorParser.parse("rgb(255, 136, 0)") == expected)
    }

    /// No syntactic rule tells `#404` from `#333`, so every three, six or eight digit value is a
    /// color. These rows pin that on purpose.
    @Test("A hex string that reads as a word or a number is still a color")
    func wordLikeHexIsAColor() {
        Self.expectColors([
            ("#123", [17, 34, 51, 1]),
            ("#404", [68, 0, 68, 1]),
            ("#500", [85, 0, 0, 1]),
            ("#bad", [187, 170, 221, 1]),
            ("#dad", [221, 170, 221, 1]),
            ("#ace", [170, 204, 238, 1]),
            ("#fed", [255, 238, 221, 1]),
            ("#facade", [250, 202, 222, 1]),
            ("#decade", [222, 202, 222, 1]),
            ("#100200", [16, 2, 0, 1]),
            ("#20250101", [32, 37, 1, 0.004]),
            ("#deadbeef", [222, 173, 190, 0.937])
        ])
    }

    @Test("Four hex digits are not a color")
    func fourDigitHexIsNotAColor() {
        Self.expectNoColor(["#f808", "#1234", "#dead", "#beef", "#face", "#cafe", "#2024"])
    }

    @Test("Any other digit count, a missing hash or a non-hex digit is not a color")
    func malformedHex() {
        Self.expectNoColor([
            "#", "#1", "#12", "#12345", "#1234567", "#123456789", "#gggggg", "#ff880g", "ff8800", "f80",
            "# 123", "#12 3", "##ff8800", "#ff8800;", "see #ff8800", "#ff8800 is orange",
            "#\u{FF11}\u{FF12}\u{FF13}", "#\u{FF46}\u{FF46}\u{FF46}"
        ])
    }

    // MARK: - Whitespace

    @Test("Whitespace around the value is not trimmed away")
    func noSurroundingWhitespace() {
        Self.expectNoColor([
            " #123", "#123 ", "\t#123", "#123\n", "#123\r\n", "#ff8800 ", "\u{00A0}#123",
            " rgb(1,2,3)", "rgb(1,2,3) ", "rgb(1,2,3)\n", " hsl(32, 100%, 50%) "
        ])
    }

    // MARK: - rgb()

    @Test("rgb() and rgba() in the comma syntax")
    func rgbCommaSyntax() {
        Self.expectColors([
            ("rgb(255, 136, 0)", [255, 136, 0, 1]),
            ("rgb(255,136,0)", [255, 136, 0, 1]),
            ("RGB(255, 136, 0)", [255, 136, 0, 1]),
            ("rgb( 255 , 136 , 0 )", [255, 136, 0, 1]),
            ("rgba(255, 136, 0, 0.5)", [255, 136, 0, 0.5]),
            ("rgba(255,136,0,.5)", [255, 136, 0, 0.5]),
            ("rgb(255, 136, 0, 50%)", [255, 136, 0, 0.5]),
            ("rgb(0, 0, 0, 0)", [0, 0, 0, 0]),
            ("rgb(100%, 53.3%, 0%)", [255, 136, 0, 1]),
            ("rgb(+1,+2,+3)", [1, 2, 3, 1]),
            ("rgb(127.5, 0, 0)", [128, 0, 0, 1])
        ])
    }

    @Test("rgb() and rgba() in the space syntax, with a slash before the alpha")
    func rgbSpaceSyntax() {
        Self.expectColors([
            ("rgb(255 136 0)", [255, 136, 0, 1]),
            ("rgb(255 136 0 / 50%)", [255, 136, 0, 0.5]),
            ("rgb(255 136 0/0.5)", [255, 136, 0, 0.5]),
            ("rgb(  255   136   0  /  .5  )", [255, 136, 0, 0.5]),
            ("rgba(1 2 3)", [1, 2, 3, 1]),
            ("rgb(100% 136 0)", [255, 136, 0, 1])
        ])
    }

    @Test("A channel or alpha outside its range clamps to the nearest end")
    func outOfRangeClamps() {
        Self.expectColors([
            ("rgb(300, -5, 0)", [255, 0, 0, 1]),
            ("rgb(150%, -10%, 0%)", [255, 0, 0, 1]),
            ("rgba(0,0,0,2)", [0, 0, 0, 1]),
            ("rgba(0,0,0,-1)", [0, 0, 0, 0]),
            ("rgb(0 0 0 / 150%)", [0, 0, 0, 1]),
            ("hsl(0, 150%, 50%)", [255, 0, 0, 1]),
            ("hsl(0, 100%, 150%)", [255, 255, 255, 1])
        ])
    }

    // MARK: - hsl()

    @Test("hsl() and hsla() in both syntaxes, with hue units and a hue that wraps")
    func hslNotations() {
        Self.expectColors([
            ("hsl(32, 100%, 50%)", [255, 136, 0, 1]),
            ("hsl(32deg 100% 50%)", [255, 136, 0, 1]),
            ("HSL(32DEG 100% 50%)", [255, 136, 0, 1]),
            ("hsla(120, 100%, 25%, 0.25)", [0, 128, 0, 0.25]),
            ("hsl(0.5turn 50% 50% / 25%)", [64, 191, 191, 0.25]),
            ("hsl(200grad, 100%, 50%)", [0, 255, 255, 1]),
            ("hsl(3.14159rad, 100%, 50%)", [0, 255, 255, 1]),
            ("hsl(-120, 100%, 50%)", [0, 0, 255, 1]),
            ("hsl(480, 100%, 50%)", [0, 255, 0, 1]),
            ("hsl(0, 0%, 100%)", [255, 255, 255, 1]),
            ("hsl(0, 0%, 0%)", [0, 0, 0, 1]),
            ("hsl(210 40% 96.1%)", [241, 245, 249, 1]),
            ("hsl(120 100 50)", [0, 255, 0, 1]),
            ("hsl(120 100% 50)", [0, 255, 0, 1])
        ])
    }

    /// `NSColor(hue:saturation:brightness:alpha:)` with the same three numbers gives 128, 68, 0.
    @Test("HSL is converted as HSL, not read as HSB")
    func hslIsNotHSB() {
        Self.expectColors([
            ("hsl(32, 100%, 50%)", [255, 136, 0, 1]),
            ("hsl(30, 100%, 30%)", [153, 77, 0, 1])
        ])
    }

    // MARK: - Malformed functions

    @Test("A trailing, leading or doubled comma is not a color")
    func strayCommaIsNotAColor() {
        Self.expectNoColor([
            "rgb(1,2,3,)", "rgba(1,2,3,)", "rgb(1,2,3, )", "rgb(1,2,)", "rgb(,1,2,3)", "rgb(1,,3)",
            "hsl(1,2%,3%,)", "rgb(1,2,3,0.5,)"
        ])
    }

    @Test("The comma and the space syntax do not mix")
    func mixedSyntaxIsNotAColor() {
        Self.expectNoColor([
            "rgb(1 2,3)", "rgb(1,2 3)", "rgb(1, 2, 3 / 0.5)", "rgb(1 2 3, 0.5)", "hsl(32, 100% 50%)",
            "rgb(100%, 136, 0)", "rgb(255, 53.3%, 0%)", "hsl(120, 100, 50)", "hsl(10,20,30)", "hsl(120, 100%, 50)"
        ])
    }

    @Test("Two components need a comma or a space between them")
    func componentsNeedASeparator() {
        Self.expectNoColor([
            "rgb(1-2 3)", "rgb(1+2 3)", "rgb(1.5.5 3)", "rgb(50%50% 50%)", "rgb(1 2-3)", "hsl(120deg50% 50%)"
        ])
    }

    @Test("Too few or too many arguments are not a color")
    func wrongArgumentCount() {
        Self.expectNoColor([
            "rgb()", "rgb( )", "rgb(255)", "rgb(255, 136)", "rgb(255 136)", "rgb(255, 136, 0, 0.5, 1)",
            "rgb(1 2 3 4)", "rgb(1 2 3 / )", "rgb(1 2 3 /)", "rgb(1 2 3 / 0.5 0.5)", "rgb(1 2 3 / 0.5 / 0.5)",
            "hsl(32)", "hsl(32, 100%)"
        ])
    }

    @Test("A token that Double() would read but CSS does not is not a number")
    func numbersOnlySwiftAccepts() {
        Self.expectNoColor([
            "rgb(nan, 0, 0)", "rgb(inf, 0, 0)", "rgb(infinity, 0, 0)", "rgb(0x10, 0, 0)", "rgb(0x1p3, 0, 0)",
            "rgb(1e2, 0, 0)", "hsl(1e3,1%,1%)", "rgb(1., 2, 3)", "rgb(--1,2,3)", "rgb(+-1,2,3)", "rgb(1.2.3,2,3)",
            "rgb(+,2,3)", "rgb(.,.,.)", "rgb(-,-,-)", "rgb(a, b, c)", "rgb(\u{FF11},\u{FF12},\u{FF13})",
            "rgb(1 %, 2%, 3%)", "rgb(1%%, 2%, 3%)"
        ])
    }

    @Test("A function that is not closed, not opened, or carries anything after it is not a color")
    func malformedFunctions() {
        Self.expectNoColor([
            "rgb (1,2,3)", "rgb(1,2,3", "rgb1,2,3)", "rgb(1,2,3))", "rgb((1,2,3)", "rgb(1,2,3);", "rgb(1,2,3)x",
            "rgb(1,\t2,3)", "rgb(1,\n2,3)", "rgb[1,2,3]", "\u{FF52}\u{FF47}\u{FF42}(1,2,3)"
        ])
    }

    @Test("A hue takes a number and one of four units, nothing else")
    func malformedHue() {
        Self.expectNoColor([
            "hsl(deg,1%,1%)", "hsl(50%, 100%, 50%)", "hsl(120foo, 100%, 50%)", "hsl(120 deg, 100%, 50%)",
            "hsl(120degrees, 100%, 50%)", "hsl(120deg%, 100%, 50%)"
        ])
    }

    @Test("Named colors and the other CSS notations are not colors")
    func otherNotationsAreNotColors() {
        Self.expectNoColor([
            "", "red", "tan", "navy", "transparent", "currentColor", "rgb", "hsl", "rgba", "0", "255, 136, 0",
            "hwb(0 0% 0%)", "lab(50% 40 59.5)", "color(srgb 1 0 0)", "rgbx(1,2,3)", "argb(1,2,3)"
        ])
    }

    // MARK: - Length

    @Test("A value of 64 bytes is parsed and one of 65 is not")
    func lengthGate() {
        let atLimit = "rgb(" + String(repeating: " ", count: 54) + "1,2,3)"
        let overLimit = "rgb(" + String(repeating: " ", count: 55) + "1,2,3)"
        #expect(atLimit.utf8.count == CSSColorParser.maxLength)
        #expect(Self.channels(atLimit) == [1, 2, 3, 1])
        #expect(overLimit.utf8.count == CSSColorParser.maxLength + 1)
        #expect(CSSColorParser.parse(overLimit) == nil)
    }

    @Test("A long value is not a color, whatever it starts with")
    func longValuesAreNotColors() {
        #expect(CSSColorParser.parse(String(repeating: "#ff8800", count: 20)) == nil)
        #expect(CSSColorParser.parse("#ff8800" + String(repeating: " ", count: 1_048_576)) == nil)
    }
}

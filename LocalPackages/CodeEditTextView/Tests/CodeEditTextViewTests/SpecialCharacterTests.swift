import AppKit
@testable import CodeEditTextView
import Testing

@Suite("Special character classification")
struct SpecialCharacterTests {
    private func classify(_ text: String, at index: Int = 0) -> SpecialCharacter? {
        SpecialCharacter.classify(in: text as NSString, at: index)?.character
    }

    @Test(
        "Controls, format characters and separators draw as a labelled marker",
        arguments: [
            ("\u{0}", "NUL"), ("\u{8}", "BS"), ("\u{1B}", "ESC"), ("\u{B}", "VT"), ("\u{C}", "FF"),
            ("\u{7F}", "DEL"), ("\u{85}", "NEL"), ("\u{9B}", "CSI"), ("\u{AD}", "SHY"),
            ("\u{200B}", "ZWSP"), ("\u{200E}", "LRM"), ("\u{202E}", "RLO"), ("\u{2066}", "LRI"),
            ("\u{2028}", "LSEP"), ("\u{2029}", "PSEP"), ("\u{2060}", "WJ"), ("\u{FEFF}", "BOM"),
            ("\u{3164}", "3164")
        ]
    )
    func markers(text: String, label: String) {
        #expect(classify(text) == .marker(label: label))
    }

    @Test(
        "A control is named by what it does and every other character by its Unicode name",
        arguments: [
            ("\u{0}", "null"), ("\u{8}", "backspace"), ("\u{1B}", "escape"), ("\u{1F}", "unit separator"),
            ("\u{7F}", "delete"), ("\u{80}", "padding character"), ("\u{85}", "next line"),
            ("\u{9B}", "control sequence introducer"), ("\u{9F}", "application program command"),
            ("\u{A0}", "no-break space"), ("\u{200B}", "zero width space"), ("\u{202E}", "right-to-left override"),
            ("\u{E0001}", "language tag")
        ]
    )
    func names(text: String, name: String) {
        #expect(SpecialCharacter.classify(in: text as NSString, at: 0)?.name == name)
    }

    @Test("Every control the classifier marks has a name of its own")
    func everyControlIsNamed() {
        for value in UInt32(0)...0x9F {
            guard let scalar = Unicode.Scalar(value),
                  let classified = SpecialCharacter.classify(in: String(Character(scalar)) as NSString, at: 0),
                  case .marker = classified.character else { continue }
            #expect(!classified.name.isEmpty && !classified.name.hasPrefix("U+"), "U+\(String(value, radix: 16))")
        }
    }

    @Test(
        "Spaces that draw as an ordinary blank are outlined",
        arguments: ["\u{A0}", "\u{2002}", "\u{200A}", "\u{202F}", "\u{205F}", "\u{3000}"]
    )
    func blankSpaces(text: String) {
        #expect(classify(text) == .blankSpace)
    }

    @Test(
        "Ordinary text is never special",
        arguments: [" ", "\t", "\n", "\r", "a", "乐", "é", "😀"]
    )
    func ordinaryText(text: String) {
        #expect(classify(text) == nil)
    }

    @Test("A joiner inside an emoji sequence is left alone")
    func joinerInsideEmoji() {
        let family = "\u{1F468}\u{200D}\u{1F469}"
        #expect(classify(family, at: 2) == nil)
    }

    @Test("A joiner between ASCII characters is revealed")
    func joinerBetweenASCII() {
        #expect(classify("a\u{200D}b", at: 1) == .marker(label: "ZWJ"))
        #expect(classify("a\u{200C}b", at: 1) == .marker(label: "ZWNJ"))
    }

    @Test("A Persian non-joiner is left alone")
    func persianNonJoiner() {
        #expect(classify("\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}", at: 2) == nil)
    }

    @Test("Variation selectors stay with the character they modify")
    func variationSelectors() {
        #expect(classify("\u{2764}\u{FE0F}", at: 1) == nil)
    }

    @Test("Tag characters are special unless they belong to a subdivision flag")
    func tagCharacters() {
        let smuggled = "a\u{E0041}"
        let flag = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        let classified = SpecialCharacter.classify(in: smuggled as NSString, at: 1)
        #expect(classified?.character == .marker(label: "E0041"))
        #expect(classified?.range == NSRange(location: 1, length: 2))
        #expect(classify(flag, at: 2) == nil)
        #expect(classify(flag, at: 12) == nil)
    }

    @Test("The fast prefilter lets through every character the classifier would flag")
    func prefilterIsASuperset() {
        for value in UInt32(0)...0xFFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = "a\(Character(scalar))a" as NSString
            guard SpecialCharacter.classify(in: text, at: 1) != nil || isFlaggable(scalar) else { continue }
            #expect(SpecialCharacter.mayBeSpecial(UInt16(value)), "U+\(String(value, radix: 16)) was filtered out")
        }
    }

    @Test("The prefilter lets through the lead surrogate of every invisible character outside the BMP")
    func prefilterCoversAstralPlanes() {
        for value in UInt32(0x10000)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value), isFlaggable(scalar) else { continue }
            let lead = UInt16(0xD800 + ((value - 0x10000) >> 10))
            #expect(SpecialCharacter.mayBeSpecial(lead), "U+\(String(value, radix: 16)) was filtered out")
        }
    }

    private func isFlaggable(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
            return !"\t\n\r".unicodeScalars.contains(scalar)
        case .spaceSeparator:
            return scalar != " "
        default:
            return properties.isDefaultIgnorableCodePoint
        }
    }

    @Test("Text input keeps tab and line breaks and drops other controls")
    func textInputControls() {
        #expect("SELECT\u{8} 1\u{7}".removingTextInputControlCharacters == "SELECT 1")
        #expect("a\tb\r\nc\n".removingTextInputControlCharacters == "a\tb\r\nc\n")
        #expect("\u{200B}\u{A0}乐".removingTextInputControlCharacters == "\u{200B}\u{A0}乐")
    }
}

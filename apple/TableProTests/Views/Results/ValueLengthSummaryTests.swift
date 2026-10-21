//
//  ValueLengthSummaryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ValueLengthSummaryTests {
    @Test("A trailing zero-width space reads as one more character and three more bytes")
    func zeroWidthSpace() {
        let summary = ValueLengthSummary("abc\u{200B}")

        #expect(summary.characterCount == 4)
        #expect(summary.byteCount == 6)
        #expect(!summary.holdsBidiControl)
    }

    @Test("Characters are code points, so a decomposed accent counts twice")
    func codePoints() {
        let summary = ValueLengthSummary("e\u{0301}")

        #expect(summary.characterCount == 2)
        #expect(summary.byteCount == 3)
    }

    @Test("Every bidirectional control raises the warning, and other format characters do not")
    func bidiControls() {
        for control in ["\u{202E}", "\u{2066}", "\u{200F}", "\u{061C}"] {
            #expect(ValueLengthSummary("abc\(control)").holdsBidiControl, "\(control.unicodeScalars.first?.value ?? 0)")
        }
        #expect(!ValueLengthSummary("abc\u{200B}\u{FEFF}").holdsBidiControl)
    }

    @Test("The readout names both counts, singular where it is one")
    func lengthText() {
        #expect(ValueLengthSummary("abc\u{200B}").lengthText == "4 characters, 6 bytes")
        #expect(ValueLengthSummary("a").lengthText == "1 character, 1 byte")
        #expect(ValueLengthSummary("").lengthText == "0 characters, 0 bytes")
    }
}

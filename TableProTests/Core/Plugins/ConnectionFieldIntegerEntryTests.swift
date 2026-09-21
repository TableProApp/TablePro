//
//  ConnectionFieldIntegerEntryTests.swift
//  TableProTests
//
//  A stepper field in the connection form is a text field paired with a stepper, so a value too
//  far from the default to reach by clicking can be typed. The text is filtered on every
//  keystroke and the stepper clamps whatever the text says.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Connection field integer entry")
struct ConnectionFieldIntegerEntryTests {
    private let redisIndexes = ConnectionField.IntRange(0...2_147_483_646)
    private let signed = ConnectionField.IntRange(-10...10)
    private let timeout = ConnectionField.IntRange(1...120)

    @Test("Clamping holds a value inside the range")
    func clamping() {
        #expect(redisIndexes.clamping(-1) == 0)
        #expect(redisIndexes.clamping(20) == 20)
        #expect(redisIndexes.clamping(Int.max) == 2_147_483_646)
        #expect(timeout.clamping(0) == 1)
    }

    @Test("Typed text keeps ASCII digits only")
    func keepsDigits() {
        let cases: [(typed: String, expected: String)] = [
            ("20", "20"),
            ("2a0", "20"),
            ("-3", "3"),
            (" 7 ", "7"),
            ("1.5", "15"),
            ("db4", "4"),
            ("\u{0663}", ""),
            ("\u{FF13}", ""),
            ("007", "7"),
            ("", ""),
        ]
        for entry in cases {
            #expect(redisIndexes.fieldText(sanitizing: entry.typed) == entry.expected, "\(entry.typed)")
        }
    }

    @Test("A value past the upper bound, or past Int, is capped at the upper bound")
    func capsAtUpperBound() {
        #expect(redisIndexes.fieldText(sanitizing: "2147483646") == "2147483646")
        #expect(redisIndexes.fieldText(sanitizing: "2147483647") == "2147483646")
        #expect(redisIndexes.fieldText(sanitizing: "99999999999999999999") == "2147483646")
        #expect(timeout.fieldText(sanitizing: "121") == "120")
    }

    @Test("A value below the lower bound is left alone while it can still grow into range")
    func leavesGrowableValues() {
        #expect(timeout.fieldText(sanitizing: "0") == "0")
        #expect(timeout.fieldText(sanitizing: "00") == "0")
    }

    @Test("A minus sign is kept only at the start of a range that allows negatives")
    func signedEntry() {
        #expect(signed.fieldText(sanitizing: "-") == "-")
        #expect(signed.fieldText(sanitizing: "-5") == "-5")
        #expect(signed.fieldText(sanitizing: "-20") == "-10")
        #expect(signed.fieldText(sanitizing: "20") == "10")
        #expect(signed.fieldText(sanitizing: "5-") == "5")
        #expect(signed.fieldText(sanitizing: "-99999999999999999999") == "-10")
        #expect(redisIndexes.fieldText(sanitizing: "-") == "")
    }

    @Test("The stepper reads the typed value, clamped")
    func stepperReadsTypedValue() {
        #expect(redisIndexes.stepperValue(fromFieldText: "20", defaultValue: "0") == 20)
        #expect(redisIndexes.stepperValue(fromFieldText: " 7 ", defaultValue: "0") == 7)
        #expect(redisIndexes.stepperValue(fromFieldText: "99999999999999999999", defaultValue: "0") == 2_147_483_646)
        #expect(timeout.stepperValue(fromFieldText: "0", defaultValue: "10") == 1)
        #expect(signed.stepperValue(fromFieldText: "-", defaultValue: "3") == 3)
    }

    @Test("An empty field steps from the default, which is what every driver reads it as")
    func emptyFieldStepsFromDefault() {
        #expect(redisIndexes.stepperValue(fromFieldText: "", defaultValue: "0") == 0)
        #expect(timeout.stepperValue(fromFieldText: "", defaultValue: "10") == 10)
        #expect(timeout.stepperValue(fromFieldText: "", defaultValue: nil) == 1)
        #expect(timeout.stepperValue(fromFieldText: "", defaultValue: "500") == 120)
        #expect(timeout.stepperValue(fromFieldText: "", defaultValue: "none") == 1)
    }
}

//
//  BooleanValueMapperTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("BooleanValueMapper.state(for:)")
struct BooleanValueMapperStateTests {
    @Test("nil maps to mixed")
    func nilMapsToMixed() {
        #expect(BooleanValueMapper.state(for: nil) == .mixed)
    }

    @Test("Empty and whitespace map to mixed")
    func emptyMapsToMixed() {
        #expect(BooleanValueMapper.state(for: "") == .mixed)
        #expect(BooleanValueMapper.state(for: "   ") == .mixed)
    }

    @Test("\"1\" maps to on")
    func oneIsOn() {
        #expect(BooleanValueMapper.state(for: "1") == .on)
    }

    @Test("\"0\" maps to off")
    func zeroIsOff() {
        #expect(BooleanValueMapper.state(for: "0") == .off)
    }

    @Test("Lowercase true/false")
    func lowercaseLiterals() {
        #expect(BooleanValueMapper.state(for: "true") == .on)
        #expect(BooleanValueMapper.state(for: "false") == .off)
    }

    @Test("Uppercase TRUE/FALSE")
    func uppercaseLiterals() {
        #expect(BooleanValueMapper.state(for: "TRUE") == .on)
        #expect(BooleanValueMapper.state(for: "FALSE") == .off)
        #expect(BooleanValueMapper.state(for: "True") == .on)
    }

    @Test("Postgres single-letter t/f")
    func singleLetterLiterals() {
        #expect(BooleanValueMapper.state(for: "t") == .on)
        #expect(BooleanValueMapper.state(for: "f") == .off)
        #expect(BooleanValueMapper.state(for: "T") == .on)
        #expect(BooleanValueMapper.state(for: "F") == .off)
    }

    @Test("Garbage maps to mixed")
    func garbageMapsToMixed() {
        #expect(BooleanValueMapper.state(for: "maybe") == .mixed)
        #expect(BooleanValueMapper.state(for: "2") == .mixed)
        #expect(BooleanValueMapper.state(for: "null") == .mixed)
    }
}

@Suite("BooleanValueMapper.rawValue(for:usesTrueFalse:)")
struct BooleanValueMapperRawValueTests {
    @Test("On round-trips with usesTrueFalse=false")
    func onIntegerStyle() {
        #expect(BooleanValueMapper.rawValue(for: .on, usesTrueFalse: false) == "1")
    }

    @Test("Off round-trips with usesTrueFalse=false")
    func offIntegerStyle() {
        #expect(BooleanValueMapper.rawValue(for: .off, usesTrueFalse: false) == "0")
    }

    @Test("On round-trips with usesTrueFalse=true")
    func onLiteralStyle() {
        #expect(BooleanValueMapper.rawValue(for: .on, usesTrueFalse: true) == "true")
    }

    @Test("Off round-trips with usesTrueFalse=true")
    func offLiteralStyle() {
        #expect(BooleanValueMapper.rawValue(for: .off, usesTrueFalse: true) == "false")
    }

    @Test("Mixed maps to nil regardless of style")
    func mixedIsNull() {
        #expect(BooleanValueMapper.rawValue(for: .mixed, usesTrueFalse: false) == nil)
        #expect(BooleanValueMapper.rawValue(for: .mixed, usesTrueFalse: true) == nil)
    }

    @Test("Round-trip integer style")
    func roundTripInteger() {
        let onState = BooleanValueMapper.state(for: BooleanValueMapper.rawValue(for: .on, usesTrueFalse: false))
        let offState = BooleanValueMapper.state(for: BooleanValueMapper.rawValue(for: .off, usesTrueFalse: false))
        #expect(onState == .on)
        #expect(offState == .off)
    }

    @Test("Round-trip literal style")
    func roundTripLiteral() {
        let onState = BooleanValueMapper.state(for: BooleanValueMapper.rawValue(for: .on, usesTrueFalse: true))
        let offState = BooleanValueMapper.state(for: BooleanValueMapper.rawValue(for: .off, usesTrueFalse: true))
        #expect(onState == .on)
        #expect(offState == .off)
    }
}

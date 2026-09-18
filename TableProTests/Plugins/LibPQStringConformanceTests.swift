//
//  LibPQStringConformanceTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("LibPQStringConformance")
struct LibPQStringConformanceTests {
    @Test("Every session turns standard_conforming_strings on")
    func sessionSetupForcesStandardConformingStrings() {
        #expect(LibPQStringConformance.enableStatement == "SET standard_conforming_strings TO on")
    }

    @Test("The setup statement and the fallback read name the parameter the connection tracks")
    func setupNamesTrackedParameter() {
        #expect(LibPQStringConformance.enableStatement.lowercased().contains(LibPQStringConformance.parameterName))
        #expect(LibPQStringConformance.showQuery.lowercased().hasSuffix(LibPQStringConformance.parameterName))
    }

    @Test("Reported values parse the way the server spells them")
    func parsesReportedValues() {
        #expect(LibPQStringConformance.isOn("on") == true)
        #expect(LibPQStringConformance.isOn("ON") == true)
        #expect(LibPQStringConformance.isOn(" on ") == true)
        #expect(LibPQStringConformance.isOn("off") == false)
        #expect(LibPQStringConformance.isOn("Off") == false)
        #expect(LibPQStringConformance.isOn(nil) == nil)
        #expect(LibPQStringConformance.isOn("maybe") == nil)
    }

    @Test("With the setting on, only quotes are doubled")
    func escapeWhenConforming() {
        #expect(LibPQStringConformance.escape("plain", standardConformingStrings: true) == "plain")
        #expect(LibPQStringConformance.escape("it's", standardConformingStrings: true) == "it''s")
        #expect(LibPQStringConformance.escape("back\\slash", standardConformingStrings: true) == "back\\slash")
    }

    @Test("With the setting off, backslashes are doubled as well")
    func escapeWhenNotConforming() {
        #expect(LibPQStringConformance.escape("plain", standardConformingStrings: false) == "plain")
        #expect(LibPQStringConformance.escape("it's", standardConformingStrings: false) == "it''s")
        #expect(LibPQStringConformance.escape("back\\slash", standardConformingStrings: false) == "back\\\\slash")
    }

    @Test("A backslash before a quote cannot close the literal when the setting is off")
    func injectionPayloadStaysInsideLiteral() {
        let payload = "\\'; CREATE TABLE injected (x int); --"
        let escaped = LibPQStringConformance.escape(payload, standardConformingStrings: false)
        #expect(escaped == "\\\\''; CREATE TABLE injected (x int); --")
        #expect(Self.decodeLegacyLiteralBody(escaped) == payload)
    }

    @Test("The escaped body decodes back to the original under either setting")
    func roundTripsUnderBothSettings() {
        let values = ["", "a", "it's", "back\\slash", "\\'", "''", "\\\\", "mixed \\' and ' and \\"]
        for value in values {
            let conforming = LibPQStringConformance.escape(value, standardConformingStrings: true)
            #expect(conforming.replacingOccurrences(of: "''", with: "'") == value)
            let legacy = LibPQStringConformance.escape(value, standardConformingStrings: false)
            #expect(Self.decodeLegacyLiteralBody(legacy) == value)
        }
    }

    @Test("NUL characters are dropped under either setting")
    func dropsNul() {
        #expect(LibPQStringConformance.escape("a\0b", standardConformingStrings: true) == "ab")
        #expect(LibPQStringConformance.escape("a\0b", standardConformingStrings: false) == "ab")
    }

    private static func decodeLegacyLiteralBody(_ body: String) -> String {
        var decoded = ""
        var iterator = Array(body).makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\\":
                if let next = iterator.next() { decoded.append(next) }
            case "'":
                if let next = iterator.next() { decoded.append(next) }
            default:
                decoded.append(character)
            }
        }
        return decoded
    }
}

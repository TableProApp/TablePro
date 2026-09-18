//
//  PluginDriverAdapterParameterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Plugin Driver Adapter Parameters")
struct PluginDriverAdapterParameterTests {
    @Test("A non-finite number binds SQL null, not the text NULL")
    func nonFiniteBindsNull() {
        #expect(PluginDriverAdapter.cellValue(for: Double.nan) == .null)
        #expect(PluginDriverAdapter.cellValue(for: Double.infinity) == .null)
        #expect(PluginDriverAdapter.cellValue(for: -Double.infinity) == .null)
        #expect(PluginDriverAdapter.cellValue(for: Float.nan) == .null)
    }

    @Test("A missing parameter binds null")
    func nilBindsNull() {
        #expect(PluginDriverAdapter.cellValue(for: nil) == .null)
    }

    @Test("A 32-bit float binds its own precision, not a widened double")
    func floatKeepsItsPrecision() {
        #expect(PluginDriverAdapter.cellValue(for: Float(1847.27)) == .text("1847.27"))
        #expect(PluginDriverAdapter.cellValue(for: Double(1847.27)) == .text("1847.27"))
    }

    @Test("A double binds every digit needed to round-trip")
    func doubleKeepsEveryDigit() {
        #expect(PluginDriverAdapter.cellValue(for: -3.9192320754595876e-07)
            == .text("-3.9192320754595876e-07"))
    }

    @Test("Other parameter kinds are unchanged")
    func otherKindsUnchanged() {
        #expect(PluginDriverAdapter.cellValue(for: "text") == .text("text"))
        #expect(PluginDriverAdapter.cellValue(for: true) == .text("1"))
        #expect(PluginDriverAdapter.cellValue(for: Int(42)) == .text("42"))
        #expect(PluginDriverAdapter.cellValue(for: Data([0x01, 0x02])) == .bytes(Data([0x01, 0x02])))
    }
}

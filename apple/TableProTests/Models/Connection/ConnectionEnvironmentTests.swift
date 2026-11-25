//
//  ConnectionEnvironmentTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProConnectionLibrary
import Testing

struct ConnectionEnvironmentTests {
    @Test("Each environment has a symbol this Mac can draw, and none has no symbol")
    func symbols() {
        #expect(ConnectionEnvironment.none.symbolName == nil)
        for environment in ConnectionEnvironment.allCases where environment != .none {
            let image = environment.symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            #expect(image != nil, "\(environment.rawValue)")
        }
    }

    @Test("Production never draws the triangle a failed status or a missing driver draws on the same row")
    func productionIsNotTheWarningTriangle() {
        let production = ConnectionEnvironment.production.symbolName
        #expect(production != ConnectionStatusSymbol.failed.systemName)
        #expect(production != ConnectionStatusSymbol.lost.systemName)
        #expect(production != "exclamationmark.triangle.fill")
    }

    @Test("Production is red, Staging orange, Development green, Local secondary")
    func tints() {
        #expect(ConnectionEnvironment.production.tint == .red)
        #expect(ConnectionEnvironment.staging.tint == .orange)
        #expect(ConnectionEnvironment.development.tint == .green)
        #expect(ConnectionEnvironment.local.tint == .secondary)
    }

    @Test("Every environment has its own symbol and tint, so Production stands apart")
    func distinctPresentation() {
        let shown = ConnectionEnvironment.allCases.filter { $0 != .none }
        let symbols = Set(shown.compactMap { $0.symbolName })
        let red = shown.filter { $0.tint == ConnectionEnvironment.production.tint }
        #expect(symbols.count == shown.count)
        #expect(red == [.production])
    }

    @Test("VoiceOver names the environment so Local does not read as the Local only sync flag")
    func accessibilityNames() {
        #expect(ConnectionEnvironment.none.accessibilityName == nil)
        #expect(ConnectionEnvironment.production.accessibilityName == "Production environment")
        #expect(ConnectionEnvironment.staging.accessibilityName == "Staging environment")
        #expect(ConnectionEnvironment.development.accessibilityName == "Development environment")
        #expect(ConnectionEnvironment.local.accessibilityName == "Local environment")
    }

    @Test("The stored field reads back as its environment, and a missing or unknown value as none")
    func storedValue() {
        #expect(ConnectionEnvironment.stored(in: [ConnectionEnvironment.fieldKey: "production"]) == .production)
        #expect(ConnectionEnvironment.stored(in: [ConnectionEnvironment.fieldKey: "local"]) == .local)
        #expect(ConnectionEnvironment.stored(in: [ConnectionEnvironment.fieldKey: "qa"]) == .none)
        #expect(ConnectionEnvironment.stored(in: [:]) == .none)
        #expect(ConnectionEnvironment.stored(in: nil) == .none)
    }
}

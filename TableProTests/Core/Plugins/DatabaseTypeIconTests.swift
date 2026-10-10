//
//  DatabaseTypeIconTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct DatabaseTypeIconTests {
    @Test("A type no plugin describes still draws a glyph")
    func unknownTypeFallsBackToASystemSymbol() {
        let type = DatabaseType(rawValue: "NoSuchEngine-\(UUID().uuidString)")
        #expect(NSImage(systemSymbolName: type.iconName, accessibilityDescription: nil) != nil)
    }
}

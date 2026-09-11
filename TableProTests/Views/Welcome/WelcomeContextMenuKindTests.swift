//
//  WelcomeContextMenuKindTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("WelcomeContextMenuKind")
struct WelcomeContextMenuKindTests {
    @Test("Nothing selected offers New Connection")
    func emptySelection() {
        #expect(WelcomeContextMenuKind.resolve(savedCount: 0, externalCount: 0) == .newConnection)
    }

    @Test("One saved connection gets its own menu")
    func singleSaved() {
        #expect(WelcomeContextMenuKind.resolve(savedCount: 1, externalCount: 0) == .singleConnection)
    }

    @Test("A saved connection selected with a linked one is a multiple selection, not a single")
    func savedWithLinked() {
        #expect(WelcomeContextMenuKind.resolve(savedCount: 1, externalCount: 1) == .multipleConnections)
    }

    @Test("Several saved connections are a multiple selection")
    func severalSaved() {
        #expect(WelcomeContextMenuKind.resolve(savedCount: 3, externalCount: 0) == .multipleConnections)
    }

    @Test("Linked rows alone get the linked menu")
    func linkedOnly() {
        #expect(WelcomeContextMenuKind.resolve(savedCount: 0, externalCount: 2) == .externalOnly)
    }
}

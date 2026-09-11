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

@Suite("WelcomeSelectionLabels")
struct WelcomeSelectionLabelsTests {
    @Test("One saved connection in a mixed selection reads as one, never as 'Delete 1 Connections'")
    func singularLabels() {
        #expect(WelcomeSelectionLabels.delete(count: 1) == String(localized: "Delete"))
        #expect(WelcomeSelectionLabels.exportToFile(count: 1) == String(localized: "Export to File…"))
        #expect(WelcomeSelectionLabels.publishToTeamCatalog(count: 1) == String(localized: "Publish to Team Catalog…"))
        #expect(WelcomeSelectionLabels.publishToTeamLibrary(count: 1) == String(localized: "Publish to Team Library…"))
        #expect(WelcomeSelectionLabels.connect(count: 1) == String(localized: "Connect"))
    }

    @Test("Several connections name their count")
    func pluralLabels() {
        #expect(WelcomeSelectionLabels.delete(count: 3).contains("3"))
        #expect(WelcomeSelectionLabels.connect(count: 2).contains("2"))
    }
}

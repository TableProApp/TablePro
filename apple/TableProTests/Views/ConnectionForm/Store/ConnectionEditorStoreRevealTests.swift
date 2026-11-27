//
//  ConnectionEditorStoreRevealTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorStoreRevealTests {
    private func postgres() -> DatabaseConnection {
        DatabaseConnection(name: "Orders", host: "db.example.com", port: 5_432, database: "orders", username: "app", type: .postgresql)
    }

    // Two issues on two rows, raised by code, so nothing has been edited yet.
    private func newStoreWithTwoIssues(_ fixture: ConnectionEditorStoreFixture) throws -> ConnectionEditorStore {
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.update {
            $0.portText = "99999"
            $0.options.connectTimeoutSeconds = 0
        }
        try #require(store.issue(for: .builtIn(.port)) != nil)
        try #require(store.issue(for: .builtIn(.connectTimeout)) != nil)
        return store
    }

    private func sidebarMarks(_ store: ConnectionEditorStore) -> Set<ConnectionFacet> {
        Set(ConnectionEditorSidebarRow.rows(for: store).filter { $0.hasIssues }.map { $0.facet })
    }

    @Test("A new form shows no issue anywhere, yet the commit bar still has the reason Save is off")
    func pristineNewFormIsNotRed() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try newStoreWithTwoIssues(fixture)

        #expect(store.revealedIssue(for: .builtIn(.port)) == nil)
        #expect(!store.facetHasRevealedErrors(.general))
        #expect(sidebarMarks(store).isEmpty)
        let first = try #require(store.firstBlockingIssue)
        #expect(!store.isRevealed(first))
        #expect(!store.canSave)
    }

    @Test("Editing a row reveals that row's issue only, in the row and the sidebar")
    func editRevealsItsRow() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try newStoreWithTwoIssues(fixture)

        store.tracking(store.portBinding, row: .builtIn(.port)).wrappedValue = "70000"

        #expect(store.revealedIssue(for: .builtIn(.port)) != nil)
        #expect(store.revealedIssue(for: .builtIn(.connectTimeout)) == nil)
        #expect(sidebarMarks(store) == [.general])
        #expect(store.facetHasRevealedErrors(.general))
        #expect(!store.facetHasRevealedErrors(.advanced))
    }

    @Test("A write from code reveals nothing; a write through the row's control does")
    func onlyControlWritesReveal() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try newStoreWithTwoIssues(fixture)

        store.binding(\.portText).wrappedValue = "80000"
        #expect(store.revealedIssue(for: .builtIn(.port)) == nil)

        store.noteEdited(.builtIn(.connectTimeout))
        #expect(store.revealedIssue(for: .builtIn(.connectTimeout)) != nil)
    }

    @Test("A Save attempt reveals every issue and focuses the first")
    func saveRevealsEverything() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try newStoreWithTwoIssues(fixture)
        store.selectedFacet = .appearance

        #expect(throws: ConnectionEditorSaveError.self) { try store.save().get() }

        #expect(store.revealedIssue(for: .builtIn(.port)) != nil)
        #expect(store.revealedIssue(for: .builtIn(.connectTimeout)) != nil)
        #expect(sidebarMarks(store) == [.general, .advanced])
        #expect(store.selectedFacet == .general)
        #expect(store.focusRequest?.row == .builtIn(.port))
    }

    @Test("A Test attempt reveals every issue, even one that keeps Test off")
    func testRevealsEverything() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try newStoreWithTwoIssues(fixture)
        #expect(!store.canTest)

        store.test()

        #expect(store.revealsAllIssues)
        #expect(store.revealedIssue(for: .builtIn(.connectTimeout)) != nil)
        #expect(store.testState == .idle)
    }

    @Test("A saved connection shows its issues from the first frame")
    func savedConnectionRevealsAtOnce() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = DatabaseConnection(name: "Local", database: "", type: .sqlite)
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        let issue = try #require(store.issue(for: .builtIn(.databaseFile)))
        #expect(store.isRevealed(issue))
        #expect(sidebarMarks(store) == [.general])
    }

    @Test("Asking the commit bar why Save is off reveals that issue and goes to it")
    func barRevealsAndFocuses() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try newStoreWithTwoIssues(fixture)
        let first = try #require(store.firstBlockingIssue)
        store.selectedFacet = .safeMode

        store.reveal(first)

        #expect(store.isRevealed(first))
        #expect(store.selectedFacet == first.facet)
        #expect(store.focusRequest?.row == first.row)
        let others = store.issues.filter { $0.row != first.row }
        #expect(!others.contains { store.isRevealed($0) })
    }

    @Test("A focus request is spent by the row that takes it, so a later row never pulls the cursor back")
    func focusRequestIsSpent() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.focus(facet: .general, row: .builtIn(.host))
        let request = try #require(store.focusRequest)

        store.didApplyFocus(FocusRequest(facet: .general, row: .builtIn(.host), token: UUID()))
        #expect(store.focusRequest == request)
        store.didApplyFocus(request)
        #expect(store.focusRequest == nil)
    }

    @Test("Initial focus is placed once per window: Host for a new connection, Name for a saved one")
    func initialFocusOnce() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let fresh = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        fresh.placeInitialFocusIfNeeded()
        let request = try #require(fresh.focusRequest)
        #expect(request.row == .builtIn(.host))
        fresh.didApplyFocus(request)
        fresh.placeInitialFocusIfNeeded()
        #expect(fresh.focusRequest == nil)

        let connection = postgres()
        fixture.seed([connection])
        let saved = fixture.makeStore(.edit(connectionId: connection.id))
        saved.placeInitialFocusIfNeeded()
        #expect(saved.focusRequest?.row == .builtIn(.name))
    }
}

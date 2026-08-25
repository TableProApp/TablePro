//
//  WorkspaceCloseActionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Workspace close scope")
@MainActor
struct WorkspaceCloseActionTests {
    @Test("An entry beside another of the same connection closes its container")
    func severalEntriesCloseTheContainer() {
        #expect(WorkspaceCloseAction.scope(entryCount: 2) == .container)
        #expect(WorkspaceCloseAction.scope(entryCount: 5) == .container)
    }

    /// A connection's last entry is the connection. Closing it as a container would leave the
    /// connection hosted with nothing in the strip to bring it back.
    @Test("A connection's only entry closes the connection")
    func lastEntryClosesTheConnection() {
        #expect(WorkspaceCloseAction.scope(entryCount: 1) == .connection)
        #expect(WorkspaceCloseAction.scope(entryCount: 0) == .connection)
    }

    @Test("Closing an entry lands on the one that takes its place")
    func neighbourTakesTheClosedRowsPlace() {
        #expect(WorkspaceCloseAction.neighbour(in: ["app", "logs", "audit"], closing: "logs") == "audit")
    }

    @Test("Closing the last entry falls back to the one before it")
    func neighbourFallsBackToThePrevious() {
        #expect(WorkspaceCloseAction.neighbour(in: ["app", "logs"], closing: "logs") == "app")
    }

    @Test("Closing the only entry leaves nowhere to go")
    func neighbourIsAbsentForASingleEntry() {
        #expect(WorkspaceCloseAction.neighbour(in: ["app"], closing: "app") == nil)
    }

    /// The entry list is read after the close, so a container that has already gone still has to
    /// name somewhere to land rather than leaving the window on a database it just closed.
    @Test("A container that is no longer listed lands on the first entry")
    func neighbourOfAnUnlistedContainerIsTheFirst() {
        #expect(WorkspaceCloseAction.neighbour(in: ["app", "logs"], closing: "audit") == "app")
        #expect(WorkspaceCloseAction.neighbour(in: [], closing: "audit") == nil)
    }
}

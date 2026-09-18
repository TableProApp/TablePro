//
//  FavoritesRenameTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import Testing

@testable import TablePro

@Suite("Favorites rename")
struct FavoritesRenameResolverTests {
    private let folderId = UUID()

    private var nodeId: String { FavoritesRenameResolver.nodeId(forFolder: folderId) }

    @Test("Nothing requested and nothing running stays put")
    func idleStaysIdle() {
        #expect(FavoritesRenameResolver.decide(session: nil, requestedFolderId: nil, nodeIds: []) == .keep)
    }

    /// A folder is asked to rename itself the moment it is created, before the cache has published
    /// it. Waiting for the row is what replaced sleeping for a fixed interval and hoping.
    @Test("A request waits for the row to exist instead of failing")
    func requestBeforeTheRowExistsWaits() {
        let decision = FavoritesRenameResolver.decide(
            session: nil, requestedFolderId: folderId, nodeIds: ["folder-other"]
        )

        #expect(decision == .keep)
    }

    @Test("A request starts once its row is on screen")
    func requestBeginsWhenTheRowArrives() {
        let decision = FavoritesRenameResolver.decide(
            session: nil, requestedFolderId: folderId, nodeIds: [nodeId]
        )

        #expect(decision == .begin(nodeId: nodeId))
    }

    @Test("A running rename is left alone while its row is still there")
    func runningRenameIsKept() {
        let session = FavoritesRenameSession(folderId: folderId, nodeId: nodeId, pendingName: "Reports")
        let decision = FavoritesRenameResolver.decide(
            session: session, requestedFolderId: folderId, nodeIds: [nodeId]
        )

        #expect(decision == .keep)
    }

    @Test("A row that disappeared during a reload cancels the edit")
    func vanishedRowCancels() {
        let session = FavoritesRenameSession(folderId: folderId, nodeId: nodeId, pendingName: "Reports")
        let decision = FavoritesRenameResolver.decide(
            session: session, requestedFolderId: folderId, nodeIds: []
        )

        #expect(decision == .cancel)
    }

    @Test("Clearing the request cancels the edit")
    func clearedRequestCancels() {
        let session = FavoritesRenameSession(folderId: folderId, nodeId: nodeId, pendingName: "Reports")
        let decision = FavoritesRenameResolver.decide(
            session: session, requestedFolderId: nil, nodeIds: [nodeId]
        )

        #expect(decision == .cancel)
    }

    @Test("A request for a different folder cancels the one running")
    func switchingFolderCancels() {
        let session = FavoritesRenameSession(folderId: folderId, nodeId: nodeId, pendingName: "Reports")
        let decision = FavoritesRenameResolver.decide(
            session: session, requestedFolderId: UUID(), nodeIds: [nodeId]
        )

        #expect(decision == .cancel)
    }
}

/// The editor lives inside the cell now, which is what makes `NSOutlineView` lay it out through a
/// disclosure change instead of leaving it painted over a neighbouring row.
@Suite("Favorites rename cell")
@MainActor
struct FavoritesRenameCellTests {
    private func makeCell() -> FavoritesOutlineCellView<Text> {
        let cell = FavoritesOutlineCellView<Text>()
        cell.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        cell.update(rootView: Text("Reports"))
        return cell
    }

    private final class Delegate: NSObject, NSTextFieldDelegate {}

    @Test("The editor is the cell's own text field, so AppKit positions it")
    func editorIsInsideTheCell() throws {
        let cell = makeCell()
        cell.beginRename(text: "Reports", delegate: Delegate())

        let field = try #require(cell.editor)
        #expect(field.superview === cell)
        #expect(cell.textField === field)
        #expect(cell.isRenaming)
    }

    @Test("The row's label is hidden while the field is up, and comes back after")
    func labelYieldsToTheEditor() throws {
        let cell = makeCell()
        let hosting = try #require(cell.subviews.first { $0 is NSHostingView<Text> })

        cell.beginRename(text: "Reports", delegate: Delegate())
        #expect(hosting.isHidden)

        cell.endRename()
        #expect(hosting.isHidden == false)
        #expect(cell.isRenaming == false)
    }

    /// A reload during an edit calls `update(rootView:)` on every visible cell, which must not put
    /// the label back over the field the user is typing in.
    @Test("A reload during an edit leaves the field on screen")
    func reloadDoesNotInterruptTheEditor() throws {
        let cell = makeCell()
        let hosting = try #require(cell.subviews.first { $0 is NSHostingView<Text> })
        cell.beginRename(text: "Reports", delegate: Delegate())

        cell.update(rootView: Text("Reports"))

        #expect(hosting.isHidden)
        #expect(cell.isRenaming)
    }

    @Test("Ending the rename returns what was typed")
    func endRenameReturnsTheTypedValue() throws {
        let cell = makeCell()
        cell.beginRename(text: "Reports", delegate: Delegate())
        try #require(cell.editor).stringValue = "Quarterly Reports"

        #expect(cell.endRename() == "Quarterly Reports")
    }

    /// A pooled cell coming back still in rename mode would put the edit field over whichever row it
    /// was handed to next. AppKit keeps a cell with a live edit out of the pool only while its field
    /// holds the keyboard, and losing focus is how an edit gets abandoned rather than finished.
    @Test("A cell taken out of rename mode gives its row back")
    func endingRenameRestoresTheRow() throws {
        let cell = makeCell()
        let hosting = try #require(cell.subviews.first { $0 is NSHostingView<Text> })
        cell.beginRename(text: "Reports", delegate: Delegate())

        cell.endRename()
        cell.update(rootView: Text("A different row"))

        #expect(hosting.isHidden == false)
        #expect(cell.editor?.isHidden == true)
        #expect(cell.isRenaming == false)
    }
}

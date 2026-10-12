//
//  DatabaseTreeReloadHoldTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// A reload drops every cell view, and dropping the field a name is being typed into ends the edit:
/// AppKit ends editing on a field that leaves the window, which committed the name as it stood and
/// closed the field. That ended the naming of a new folder the moment the store's own change
/// notification reloaded the tree. A reload asked for mid-edit therefore waits for the edit.
@MainActor
struct DatabaseTreeReloadHoldTests {
    private struct Fixture {
        let scrollView: NSScrollView
        let outlineView: NSOutlineView
        let coordinator: DatabaseTreeOutlineCoordinator
        let node: DatabaseTreeNode
        let folder: TableFolder
    }

    private func makeFixture() throws -> Fixture {
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "ReloadHoldColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let folder = TableFolder(
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
            name: "New Folder"
        )
        let node = DatabaseTreeNode(
            id: DatabaseTreeNode.tableFolderId(folder.id),
            kind: .tableFolder(DatabaseTreeFolderRef(folder: folder, members: []))
        )
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.childrenCache = ["": [node], node.id: []]
        coordinator.nodeCache = [node.id: node]
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        outlineView.reloadData()
        return Fixture(scrollView: scrollView, outlineView: outlineView, coordinator: coordinator, node: node, folder: folder)
    }

    @Test("A reload asked for during a rename waits, and the field stays open")
    func reloadWaitsForRename() throws {
        let fixture = try makeFixture()
        fixture.coordinator.beginRename(.folder(fixture.folder))
        #expect(fixture.coordinator.renameSession?.nodeId == fixture.node.id)

        fixture.coordinator.refresh()

        #expect(fixture.coordinator.isReloadDeferred)
        #expect(fixture.coordinator.renameSession?.nodeId == fixture.node.id)
        let cell = fixture.outlineView.view(atColumn: 0, row: 0, makeIfNecessary: false) as? DatabaseTreeCellView
        #expect(cell?.isRenaming == true)
        _ = fixture.scrollView
    }

    @Test("The held reload runs as soon as the rename ends")
    func heldReloadRunsWhenRenameEnds() throws {
        let fixture = try makeFixture()
        fixture.coordinator.beginRename(.folder(fixture.folder))
        fixture.coordinator.refresh()

        fixture.coordinator.endRename(commit: false)

        #expect(!fixture.coordinator.isReloadDeferred)
        #expect(fixture.coordinator.renameSession == nil)
        _ = fixture.scrollView
    }

    @Test("A reload during a drag waits for the drag to end")
    func reloadWaitsForDrag() throws {
        let fixture = try makeFixture()
        fixture.coordinator.isDragging = true

        fixture.coordinator.refresh()
        #expect(fixture.coordinator.isReloadDeferred)
        #expect(fixture.coordinator.childrenCache[""]?.first === fixture.node)

        fixture.coordinator.isDragging = false
        fixture.coordinator.applyDeferredReloadIfNeeded()
        #expect(!fixture.coordinator.isReloadDeferred)
        _ = fixture.scrollView
    }
}

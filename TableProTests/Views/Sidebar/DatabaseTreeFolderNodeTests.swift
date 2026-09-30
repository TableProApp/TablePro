//
//  DatabaseTreeFolderNodeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct DatabaseTreeFolderNodeTests {
    private let folder = TableFolder(
        scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: "public"),
        name: "Billing"
    )

    private var folderKind: DatabaseTreeNode.Kind {
        .tableFolder(DatabaseTreeFolderRef(folder: folder, members: []))
    }

    @Test("A folder is an ordinary container row the user can select and open")
    func folderIsAnOrdinaryRow() {
        let node = DatabaseTreeNode(id: DatabaseTreeNode.tableFolderId(folder.id), kind: folderKind)

        #expect(node.isExpandable)
        #expect(!node.isGroupRow)
        #expect(!node.isContainer)
        #expect(node.folderRef?.folder == folder)
        #expect(DatabaseTreeSelection.isSelectable(folderKind))
        #expect(DatabaseTreeDoubleClickResolver.resolve(node: node) == .toggleDisclosure)
    }

    @Test("The Folders section is a source-list header, like Recent")
    func foldersSectionIsAHeader() {
        let node = DatabaseTreeNode(id: DatabaseTreeNode.foldersSectionId, kind: .foldersSection)

        #expect(node.isExpandable)
        #expect(node.isGroupRow)
        #expect(!DatabaseTreeSelection.isSelectable(.foldersSection))
        #expect(DatabaseTreeTypeSelect.matchString(for: .foldersSection) == nil)
    }

    @Test("Typing a folder's name selects it")
    func typeSelectMatchesTheName() {
        #expect(DatabaseTreeTypeSelect.matchString(for: folderKind) == "Billing")
    }

    @Test("A folder's row id cannot collide with a table's or a section's")
    func folderIdsAreDistinct() {
        let table = DatabaseTreeTableRef(database: "shop", schema: "public", table: TestFixtures.makeTableInfo(name: "Billing"))
        let ids = [
            DatabaseTreeNode.tableFolderId(folder.id),
            DatabaseTreeNode.tableId(table),
            DatabaseTreeNode.foldersSectionId,
            DatabaseTreeNode.recentSectionId
        ]
        #expect(Set(ids).count == ids.count)
    }

    @Test("VoiceOver reads a folder's name, its role and how much it holds")
    func folderAccessibilityLabel() {
        #expect(DatabaseTreeRowLabel.folder(name: "Billing", memberCount: 3).contains("Billing"))
        #expect(DatabaseTreeRowLabel.folder(name: "Billing", memberCount: 1)
            != DatabaseTreeRowLabel.folder(name: "Billing", memberCount: 2))
    }

    @Test("A drag token keeps a row id that itself holds the separator")
    func dragTokenRoundTrips() {
        let table = DatabaseTreeTableRef(database: "shop", schema: "public", table: TestFixtures.makeTableInfo(name: "orders"))
        let token = SidebarObjectDragToken(connectionId: UUID(), nodeId: DatabaseTreeNode.tableId(table))

        #expect(SidebarObjectDragToken(encoded: token.encoded) == token)
        #expect(SidebarObjectDragToken(encoded: "not a token") == nil)
    }

    @Test("A folder the user closed stays closed after the window state is read back")
    func collapsedFoldersPersist() throws {
        let suite = "DatabaseTreeFolderNodeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionId = UUID()

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        state.collapsedTableFolders.insert(folder.id)

        let reloaded = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(reloaded.collapsedTableFolders == [folder.id])
    }
}

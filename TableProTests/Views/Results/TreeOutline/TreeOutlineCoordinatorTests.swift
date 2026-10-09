//
//  TreeOutlineCoordinatorTests.swift
//  TableProTests
//
//  The outline is driven without a window: rows, selection, expansion, copy and the menu are all
//  reachable through `NSOutlineView` itself.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct TreeOutlineCoordinatorTests {
    private func key(_ code: KeyCode) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: code == .space ? " " : "\u{1B}",
            charactersIgnoringModifiers: code == .space ? " " : "\u{1B}",
            isARepeat: false,
            keyCode: code.rawValue
        ))
    }

    private var copyItem: NSMenuItem {
        NSMenuItem(title: "Copy", action: #selector(TreeOutlineView.copy(_:)), keyEquivalent: "c")
    }

    // MARK: - Rows

    @Test("Top-level containers open by default and deeper ones stay closed")
    func defaultExpansion() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)

        #expect(harness.keys == ["name", "site", "brand", "theme", "ink", "deep", "count"])
    }

    @Test("Applying the same content twice reloads nothing")
    func unchangedContentDoesNotReload() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
        #expect(harness.coordinator.reloadCount == 1)

        harness.apply()
        harness.apply()

        #expect(harness.coordinator.reloadCount == 1)
    }

    @Test("The rows follow the filter and come back when it is cleared")
    func rowsFollowTheFilter() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)

        harness.filter("leaf")
        #expect(harness.keys == ["theme", "deep", "leaf"])

        harness.filter("")
        #expect(harness.keys == ["name", "site", "brand", "theme", "ink", "deep", "count"])
    }

    // MARK: - Copy

    @Test("Copy writes the selected rows one per line in display order")
    func copyWritesSelectedRowsInDisplayOrder() throws {
        try TreeOutlineFixture.withClipboard { clipboard in
            let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
            try harness.select("count", "name", "brand")

            harness.outline.copy(nil)

            #expect(clipboard.writes == ["Acme\n#ff8800\n42"])
        }
    }

    @Test("Copy skips the rows of a selected container and writes it once, whole")
    func copySkipsRowsUnderASelectedContainer() throws {
        try TreeOutlineFixture.withClipboard { clipboard in
            let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
            try harness.select("theme", "ink", "deep", "count")

            harness.outline.copy(nil)

            #expect(clipboard.writes == [##"{"ink":"#1e1e1e","deep":{"leaf":1}}"## + "\n42"])
        }
    }

    @Test("Copy of a container under a filter writes the whole container, not the rows that matched")
    func copyUnderAFilterWritesTheSourceNode() throws {
        try TreeOutlineFixture.withClipboard { clipboard in
            let harness = try TreeOutlineHarness(json: TreeOutlineFixture.invoice)
            harness.filter("pear")
            #expect(harness.keys == ["invoice", "lines", "[1]", "sku"])
            try harness.select("invoice")

            harness.outline.copy(nil)

            #expect(clipboard.writes == [#"{"no":"INV-9","lines":[{"sku":"apple","n":2},{"sku":"pear","n":5}],"paid":false}"#])
        }
    }

    @Test("Copy Value from the menu copies the source node as well")
    func copyValueCommandWritesTheSourceNode() throws {
        try TreeOutlineFixture.withClipboard { clipboard in
            let harness = try TreeOutlineHarness(json: TreeOutlineFixture.invoice)
            harness.filter("pear")

            harness.coordinator.perform(.copyValue, on: [try harness.item("lines")])

            #expect(clipboard.writes == [#"[{"sku":"apple","n":2},{"sku":"pear","n":5}]"#])
        }
    }

    @Test("Copy is validated off with nothing selected, and writes nothing if sent anyway")
    func copyIsOffWithoutASelection() throws {
        try TreeOutlineFixture.withClipboard { clipboard in
            let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
            #expect(!harness.outline.validateUserInterfaceItem(copyItem))

            harness.outline.copy(nil)
            #expect(clipboard.writes.isEmpty)

            try harness.select("name")
            #expect(harness.outline.validateUserInterfaceItem(copyItem))
        }
    }

    @Test("A selection of only the truncation marker has nothing to copy")
    func markerAloneIsNotCopyable() throws {
        try TreeOutlineFixture.withClipboard { clipboard in
            let numbers = (0 ..< TreeNodeLimits.maxNodes + 20).map(String.init).joined(separator: ",")
            let harness = try TreeOutlineHarness(json: "[\(numbers)]")
            let lastRow = harness.outline.numberOfRows - 1
            let last = try #require(harness.items.last)
            #expect(last.node.isTruncationMarker)

            harness.outline.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
            #expect(!harness.outline.validateUserInterfaceItem(copyItem))
            harness.outline.copy(nil)
            #expect(clipboard.writes.isEmpty)

            harness.outline.selectRowIndexes(IndexSet([lastRow - 1, lastRow]), byExtendingSelection: false)
            #expect(harness.outline.validateUserInterfaceItem(copyItem))
            harness.outline.copy(nil)
            #expect(clipboard.writes.count == 1)
            #expect(clipboard.writes.first?.contains("\n") == false)
        }
    }

    @Test("Select All selects every row")
    func selectAllSelectsEveryRow() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)

        harness.outline.selectAll(nil)

        #expect(harness.outline.selectedRowIndexes.count == harness.outline.numberOfRows)
    }

    // MARK: - Selection

    @Test("The selection follows its rows through a filter keystroke")
    func selectionSurvivesAFilter() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
        try harness.select("ink", "count")
        #expect(harness.outline.selectedRowIndexes == IndexSet([4, 6]))

        harness.filter("1e1e")

        #expect(harness.keys == ["theme", "ink"])
        #expect(harness.selectedKeys == ["ink"])
        #expect(harness.outline.selectedRowIndexes == IndexSet(integer: 1))

        harness.filter("")
        #expect(harness.selectedKeys == ["ink"])
    }

    @Test("A new document clears the selection even where the same path exists")
    func newDocumentClearsTheSelection() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
        try harness.select("name", "ink")

        try harness.reparse(TreeOutlineFixture.profile)

        #expect(harness.outline.selectedRowIndexes.isEmpty)
        #expect(harness.keys == ["name", "site", "brand", "theme", "ink", "deep", "count"])
    }

    @Test("Escape clears a selection, and does nothing more that time")
    func escapeClearsTheSelection() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
        try harness.select("name", "site")

        harness.outline.keyDown(with: try key(.escape))
        #expect(harness.outline.selectedRowIndexes.isEmpty)

        try harness.select("name")
        harness.outline.cancelOperation(nil)
        #expect(harness.outline.selectedRowIndexes.isEmpty)
    }

    // MARK: - Links

    @Test("Space opens the link of the one selected row")
    func spaceOpensTheSelectedLink() throws {
        try TreeOutlineFixture.withOpener { opened in
            let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
            try harness.select("site")

            harness.outline.keyDown(with: try key(.space))

            #expect(opened.urls.map(\.absoluteString) == ["https://example.com/docs"])
        }
    }

    @Test("Nothing opens for a row that is not a link, or for a selection of several rows")
    func nothingOpensWithoutASingleLinkRow() throws {
        try TreeOutlineFixture.withOpener { opened in
            let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)

            #expect(!harness.coordinator.openSelectedLink())
            try harness.select("name")
            #expect(!harness.coordinator.openSelectedLink())
            try harness.select("site", "name")
            #expect(!harness.coordinator.openSelectedLink())
            #expect(opened.urls.isEmpty)

            try harness.select("site")
            #expect(harness.coordinator.openSelectedLink())
            #expect(opened.urls.count == 1)
        }
    }

    @Test("Open Link and Copy Link act on the row's URL")
    func linkCommands() throws {
        try TreeOutlineFixture.withClipboard { clipboard in
            try TreeOutlineFixture.withOpener { opened in
                let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
                let site = try harness.item("site")

                harness.coordinator.perform(.openLink, on: [site])
                harness.coordinator.perform(.copyLink, on: [site])
                harness.coordinator.perform(.openLink, on: [try harness.item("name")])
                harness.coordinator.perform(.copyLink, on: [try harness.item("name")])

                #expect(opened.urls.map(\.absoluteString) == ["https://example.com/docs"])
                #expect(clipboard.writes == ["https://example.com/docs"])
            }
        }
    }

    // MARK: - Menu

    @Test("A menu on a selected row acts on the selection, and on any other row acts on that row")
    func menuTargets() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
        try harness.select("name", "brand")

        let inside = harness.coordinator.rows(forMenuAt: try harness.row("brand"))
        let outside = harness.coordinator.rows(forMenuAt: try harness.row("count"))

        #expect(inside.map(\.node.key) == ["name", "brand"])
        #expect(outside.map(\.node.key) == ["count"])
        #expect(harness.coordinator.rows(forMenuAt: -1).isEmpty)
    }

    @Test("The built menu holds the layout's titles and ends on a command")
    func builtMenu() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)

        let leaf = try #require(harness.coordinator.fieldEditorMenu(forRow: try harness.row("name"), hasTextSelection: false))
        let link = try #require(harness.coordinator.fieldEditorMenu(forRow: try harness.row("site"), hasTextSelection: true))

        #expect(leaf.items.map(\.title) == [
            TreeOutlineMenuCommand.copyValue.title,
            TreeOutlineMenuCommand.copyKeyPath.title,
            TreeOutlineMenuCommand.copyKey.title
        ])
        #expect(leaf.items.last?.isSeparatorItem == false)
        #expect(link.items.first?.title == TreeOutlineMenuCommand.copyText.title)
        #expect(link.items.contains { $0.title == TreeOutlineMenuCommand.openLink.title })
        #expect(link.items.last?.isSeparatorItem == false)
        #expect(link.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.action != nil && $0.target === harness.coordinator })
    }

    @Test("Copy Key Path, Copy Key, Expand All and Collapse All reach their handlers")
    func otherCommands() throws {
        try TreeOutlineFixture.withClipboard { clipboard in
            let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
            let rows = [try harness.item("theme"), try harness.item("ink")]

            harness.coordinator.perform(.copyKeyPath, on: rows)
            harness.coordinator.perform(.copyKey, on: rows)
            harness.coordinator.perform(.expandAll, on: rows)
            harness.coordinator.perform(.collapseAll, on: rows)

            #expect(clipboard.writes == ["$.theme\n$.theme.ink", "theme\nink"])
            #expect(harness.expandAllCount == 1)
            #expect(harness.collapseAllCount == 1)
        }
    }

    // MARK: - Expansion

    @Test("Closing a row in the outline is reported, and the row stays closed over a reload")
    func userCollapseIsReportedAndKept() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
        let theme = try harness.item("theme")

        harness.outline.collapseItem(theme)
        #expect(harness.reported == [theme.path])
        harness.apply()
        #expect(harness.keys == ["name", "site", "brand", "theme", "count"])

        harness.filter("acme")
        harness.filter("")
        #expect(harness.keys == ["name", "site", "brand", "theme", "count"])
    }

    @Test("Expansion the coordinator applies is not reported back as a user choice")
    func appliedExpansionIsNotReported() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
        let containers = harness.cache.documentInfo(for: harness.root).allContainerPaths

        harness.disclosure.expandAll(containerPaths: containers, isFiltered: false)
        harness.apply()
        #expect(harness.keys == ["name", "site", "brand", "theme", "ink", "deep", "leaf", "count"])

        harness.disclosure.collapseAll(containerPaths: containers, isFiltered: false)
        harness.apply()
        #expect(harness.keys == ["name", "site", "brand", "theme", "count"])
        #expect(harness.reported.isEmpty)
    }

    @Test("A row closed by Collapse All opens alone, without the rows that were open under it")
    func reopeningShowsOnlyWhatTheStateSays() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
        let containers = harness.cache.documentInfo(for: harness.root).allContainerPaths
        harness.disclosure.expandAll(containerPaths: containers, isFiltered: false)
        harness.apply()
        harness.disclosure.collapseAll(containerPaths: containers, isFiltered: false)
        harness.apply()

        harness.outline.expandItem(try harness.item("theme"))
        harness.apply()

        #expect(harness.keys == ["name", "site", "brand", "theme", "ink", "deep", "count"])
    }

    @Test("A filter opens the rows that lead to a match")
    func filterRevealsMatches() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
        harness.outline.collapseItem(try harness.item("theme"))
        harness.apply()

        harness.filter("leaf")

        #expect(harness.keys == ["theme", "deep", "leaf"])
        #expect(harness.reported.count == 1)
    }

    @Test("A large document opens every wanted row and leaves the rest closed")
    func bulkExpansionMatchesTheState() throws {
        let rows = (0 ..< 200).map { #"{"id":\#($0),"tags":["a","b"]}"# }.joined(separator: ",")
        let harness = try TreeOutlineHarness(json: "[\(rows)]")
        #expect(harness.outline.numberOfRows == 200 * 3)

        let containers = harness.cache.documentInfo(for: harness.root).allContainerPaths
        harness.disclosure.collapseAll(containerPaths: containers, isFiltered: false)
        harness.apply()
        #expect(harness.outline.numberOfRows == 200)

        harness.disclosure.expandAll(containerPaths: containers, isFiltered: false)
        let closed = try #require(harness.root.children.dropFirst(7).first)
        harness.disclosure.setExpanded(false, path: closed.path, isFiltered: false)
        harness.apply()

        let closedRow = try #require(harness.items.first { $0.path == closed.path })
        #expect(harness.outline.numberOfRows == 199 * 5 + 1)
        #expect(!harness.outline.isItemExpanded(closedRow))
        #expect(harness.reported.isEmpty)
    }

    // MARK: - Fonts

    @Test("The row height comes from the fonts, and a font change keeps rows and selection")
    func fontChange() throws {
        let harness = try TreeOutlineHarness(json: TreeOutlineFixture.profile)
        try harness.select("ink")
        #expect(harness.outline.rowHeight == TreeOutlineFixture.fonts.rowHeight)

        harness.fonts = TreeOutlineFonts(
            value: .monospacedSystemFont(ofSize: 18, weight: .regular),
            key: .monospacedSystemFont(ofSize: 18, weight: .medium)
        )
        harness.apply()

        #expect(harness.outline.rowHeight == harness.fonts.rowHeight)
        #expect(harness.outline.rowHeight > TreeOutlineFixture.fonts.rowHeight)
        #expect(harness.coordinator.reloadCount == 1)
        #expect(harness.selectedKeys == ["ink"])
    }

    @Test("The outline is the configuration the tree needs")
    func outlineConfiguration() {
        let outline = TreeOutlineView.make()

        #expect(outline.allowsMultipleSelection)
        #expect(outline.allowsEmptySelection)
        #expect(outline.style == .inset)
        #expect(outline.usesAlternatingRowBackgroundColors)
        #expect(outline.headerView == nil)
        /// With a double action set, a table never lets a value's text be selected.
        #expect(outline.doubleAction == nil)
        #expect(outline.accessibilityIdentifier() == "tree-outline")
    }
}

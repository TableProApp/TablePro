//
//  TreeOutlineMenuLayoutTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TreeOutlineMenuLayoutTests {
    private typealias Entry = TreeOutlineMenuEntry

    private func child(_ key: String, of json: String = TreeOutlineFixture.profile) throws -> JSONTreeNode {
        let root = try TreeOutlineFixture.parse(json)
        return try #require(root.children.first { $0.key == key })
    }

    @Test("A leaf row offers the three copies and does not end on a separator")
    func leafRow() throws {
        let entries = TreeOutlineMenuLayout.entries(for: [try child("name")])

        #expect(entries == [.command(.copyValue), .command(.copyKeyPath), .command(.copyKey)])
    }

    @Test("A container row adds Expand All and Collapse All after one separator")
    func containerRow() throws {
        let entries = TreeOutlineMenuLayout.entries(for: [try child("theme")])

        #expect(entries == [
            .command(.copyValue), .command(.copyKeyPath), .command(.copyKey),
            .separator,
            .command(.expandAll), .command(.collapseAll)
        ])
    }

    @Test("A link row leads with Open Link and Copy Link")
    func linkRow() throws {
        let site = try child("site")

        #expect(TreeOutlineMenuLayout.link(of: [site])?.absoluteString == "https://example.com/docs")
        #expect(TreeOutlineMenuLayout.entries(for: [site]) == [
            .command(.openLink), .command(.copyLink),
            .separator,
            .command(.copyValue), .command(.copyKeyPath), .command(.copyKey)
        ])
    }

    @Test("A color row and a plain string row get no link commands")
    func nonLinkRows() throws {
        for key in ["brand", "name", "count"] {
            let row = try child(key)
            #expect(TreeOutlineMenuLayout.link(of: [row]) == nil)
            #expect(!TreeOutlineMenuLayout.entries(for: [row]).contains(.command(.openLink)))
        }
    }

    @Test("A selection of several rows never offers to open a link")
    func severalRows() throws {
        let entries = TreeOutlineMenuLayout.entries(for: [try child("site"), try child("name")])

        #expect(entries == [.command(.copyValue), .command(.copyKeyPath), .command(.copyKey)])
    }

    @Test("The JSON truncation marker has no menu at all")
    func jsonMarker() {
        #expect(TreeOutlineMenuLayout.entries(for: [TreeOutlineFixture.marker()]).isEmpty)
    }

    @Test("A PHP depth marker keeps its key commands and loses Copy Value")
    func phpDepthMarker() {
        let marker = PhpTreeNode(
            key: "deep",
            keyPath: "$.deep",
            path: TreeNodePath.root.appending(.key("deep", occurrence: 0)),
            nodeType: .truncated,
            displayValue: "Maximum depth reached"
        )

        #expect(TreeOutlineMenuLayout.entries(for: [marker]) == [.command(.copyKeyPath), .command(.copyKey)])
    }

    @Test("A primitive document has a path and no key")
    func primitiveRoot() throws {
        let root = try TreeOutlineFixture.parse("42")

        #expect(TreeOutlineMenuLayout.entries(for: [root]) == [.command(.copyValue), .command(.copyKeyPath)])
    }

    @Test("The field editor's menu puts Copy for the selected text first")
    func fieldEditorMenu() throws {
        let entries = TreeOutlineMenuLayout.entries(for: [try child("site")], hasTextSelection: true)

        #expect(entries.prefix(4) == [.command(.copyText), .separator, .command(.openLink), .command(.copyLink)])
    }

    @Test("No menu starts or ends on a separator, or has two in a row")
    func separatorsOnlyBetweenGroups() throws {
        let root = try TreeOutlineFixture.parse(TreeOutlineFixture.profile)
        let selections: [[JSONTreeNode]] = root.children.map { [$0] }
            + [root.children, [TreeOutlineFixture.marker()], [try child("theme"), TreeOutlineFixture.marker()]]

        for rows in selections {
            for hasTextSelection in [false, true] {
                let entries = TreeOutlineMenuLayout.entries(for: rows, hasTextSelection: hasTextSelection)
                #expect(entries.first != .separator)
                #expect(entries.last != .separator)
                #expect(!zip(entries, entries.dropFirst()).contains { $0 == .separator && $1 == .separator })
            }
        }
    }

    @Test("Every command has a title")
    func titles() {
        #expect(TreeOutlineMenuCommand.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(Set(TreeOutlineMenuCommand.allCases.map(\.title)).count == TreeOutlineMenuCommand.allCases.count)
    }
}

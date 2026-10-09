//
//  TreeSelectionTextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TreeSelectionTextTests {
    private static var account: PhpValue {
        .array([
            PhpKeyValue(
                key: .string("user"),
                value: .object(
                    className: "User",
                    properties: [
                        PhpProperty(name: "name", visibility: .publicVisibility, value: .string("Ada")),
                        PhpProperty(name: "age", visibility: .publicVisibility, value: .int(36))
                    ]
                )
            ),
            PhpKeyValue(
                key: .string("tags"),
                value: .array([
                    PhpKeyValue(key: .int(0), value: .string("admin")),
                    PhpKeyValue(key: .int(1), value: .string("Ada's"))
                ])
            )
        ])
    }

    private func noSource(_ path: TreeNodePath) -> JSONTreeNode? { nil }

    /// Every row of a fully expanded outline, in the order it draws them.
    private func displayed<Node: FilterableTreeNode>(_ nodes: [Node]) -> [Node] {
        nodes.flatMap { [$0] + displayed($0.children) }
    }

    @Test("Values are joined one per line in the order the rows are given")
    func valuesKeepDisplayOrder() throws {
        let root = try TreeOutlineFixture.parse(#"{"b":"second","a":"first","n":3,"t":true,"z":null}"#)

        let text = TreeSelectionText.values(of: root.children, source: noSource)

        #expect(text == "second\nfirst\n3\ntrue\nnull")
    }

    @Test("A row with a selected ancestor is not copied again")
    func selectedAncestorCarriesItsDescendants() throws {
        let root = try TreeOutlineFixture.parse(TreeOutlineFixture.invoice)
        let invoice = try #require(root.children.first)
        let lines = try #require(invoice.children.first { $0.key == "lines" })
        let firstLine = try #require(lines.children.first)
        let sku = try #require(firstLine.children.first)
        let note = try #require(root.children.last)

        let text = TreeSelectionText.values(of: [invoice, lines, firstLine, sku, note], source: noSource)

        #expect(text == #"{"no":"INV-9","lines":[{"sku":"apple","n":2},{"sku":"pear","n":5}],"paid":false}"# + "\nx")
    }

    @Test("Siblings under an unselected parent are each copied")
    func siblingsAreCopiedSeparately() throws {
        let root = try TreeOutlineFixture.parse(TreeOutlineFixture.invoice)
        let invoice = try #require(root.children.first)
        let number = try #require(invoice.children.first)
        let paid = try #require(invoice.children.last)

        #expect(TreeSelectionText.values(of: [number, paid], source: noSource) == "INV-9\nfalse")
    }

    @Test("A truncation marker is skipped, and a selection of only markers copies nothing")
    func markersAreSkipped() throws {
        let root = try TreeOutlineFixture.parse(#"{"a":1}"#)
        let leaf = try #require(root.children.first)
        let marker = TreeOutlineFixture.marker()

        #expect(TreeSelectionText.values(of: [leaf, marker], source: noSource) == "1")
        #expect(TreeSelectionText.values(of: [marker], source: noSource) == nil)
        #expect(TreeSelectionText.values(of: [JSONTreeNode](), source: noSource) == nil)
        #expect(!TreeSelectionText.hasValue(in: [marker]))
        #expect(TreeSelectionText.hasValue(in: [marker, leaf]))
    }

    @Test("Under a filter a container copies the node the document parsed, not the rows on screen")
    @MainActor
    func filteredContainerCopiesTheSourceNode() throws {
        let root = try TreeOutlineFixture.parse(TreeOutlineFixture.invoice)
        let cache = TreeProjectionCache<JSONTreeNode>()
        let projection = cache.projection(for: root, searchText: "pear")
        let visibleInvoice = try #require(projection.nodes.first)
        #expect(visibleInvoice.copyableValue == #"{"lines":[{"sku":"pear"}]}"#)

        let text = TreeSelectionText.values(of: [visibleInvoice]) { cache.sourceNode(at: $0, in: root) }

        #expect(text == #"{"no":"INV-9","lines":[{"sku":"apple","n":2},{"sku":"pear","n":5}],"paid":false}"#)
    }

    @Test("A JSON selection of every row on screen under a filter copies the parsed container once")
    @MainActor
    func filteredJSONSelectAllCopiesTheContainerOnce() throws {
        let root = try TreeOutlineFixture.parse(TreeOutlineFixture.invoice)
        let cache = TreeProjectionCache<JSONTreeNode>()
        let rows = displayed(cache.projection(for: root, searchText: "pear").nodes)
        #expect(rows.map { $0.key ?? "" } == ["invoice", "lines", "[1]", "sku"])

        let text = TreeSelectionText.values(of: rows) { cache.sourceNode(at: $0, in: root) }

        #expect(text == #"{"no":"INV-9","lines":[{"sku":"apple","n":2},{"sku":"pear","n":5}],"paid":false}"#)
    }

    // MARK: - PHP

    @Test("A PHP container copies its summary, so a selected child under it is copied too")
    func phpContainerAndChild() throws {
        let root = PhpTreeBuilder.build(from: Self.account, formats: .english)
        let user = try #require(root.children.first)
        let name = try #require(user.children.first)

        #expect(TreeSelectionText.values(of: [user, name]) { _ in nil } == "User {2 properties}\nAda")
    }

    @Test("Selecting every PHP row copies every value, containers as their summaries")
    func phpSelectAll() {
        let root = PhpTreeBuilder.build(from: Self.account, formats: .english)
        let rows = displayed(root.children)

        let text = TreeSelectionText.values(of: rows) { _ in nil }

        #expect(text == "User {2 properties}\nAda\n36\n[2 items]\nadmin\nAda's")
    }

    @Test("Under a filter, selecting every PHP row copies the matching children with their containers")
    @MainActor
    func phpFilteredSelectAll() {
        let root = PhpTreeBuilder.build(from: Self.account, formats: .english)
        let cache = TreeProjectionCache<PhpTreeNode>()
        let rows = displayed(cache.projection(for: root, searchText: "ada").nodes)
        #expect(rows.map { $0.key ?? "" } == ["user", "name", "tags", "[1]"])

        let text = TreeSelectionText.values(of: rows) { cache.sourceNode(at: $0, in: root) }

        #expect(text == "User {2 properties}\nAda\n[2 items]\nAda's")
    }

    @Test("Key paths and keys are joined the same way, leaving out rows that have none")
    func keyPathsAndKeys() throws {
        let root = try TreeOutlineFixture.parse(#"{"a":[10,20],"b.c":1}"#)
        let array = try #require(root.children.first)
        let dotted = try #require(root.children.last)
        let rows = [array] + array.children + [dotted, TreeOutlineFixture.marker()]

        #expect(TreeSelectionText.keyPaths(of: rows) == "$.a\n$.a[0]\n$.a[1]\n$.\"b.c\"")
        #expect(TreeSelectionText.keys(of: rows) == "a\n[0]\n[1]\nb.c")
        #expect(TreeSelectionText.keyPaths(of: [TreeOutlineFixture.marker()]) == nil)
        #expect(TreeSelectionText.keys(of: [TreeOutlineFixture.marker()]) == nil)
    }
}

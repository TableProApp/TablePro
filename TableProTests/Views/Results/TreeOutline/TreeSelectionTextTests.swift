//
//  TreeSelectionTextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TreeSelectionTextTests {
    private func noSource(_ path: TreeNodePath) -> JSONTreeNode? { nil }

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

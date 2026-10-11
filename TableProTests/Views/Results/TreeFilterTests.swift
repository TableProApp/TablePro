import Foundation
import Testing

@testable import TablePro

extension TreeSummaryFormats {
    static let english = TreeSummaryFormats(
        keys: Count(one: "1 key", many: "%lld keys"),
        items: Count(one: "1 item", many: "%lld items"),
        properties: Count(one: "1 property", many: "%lld properties")
    )
}

struct TreeFilterTests {
    @Test("nested matches preserve identities and reveal their ancestors")
    func nestedMatchesPreserveIdentitiesAndRevealAncestors() throws {
        let root = try parse(#"{"account":{"profile":{"city":"needle"}}}"#)
        let account = try #require(root.children.first)
        let profile = account.children.first
        let profileNode = try #require(profile)

        let projection = TreeFilter.projection(rootNode: root, searchText: "needle")
        let visibleAccount = try #require(projection.nodes.first)
        let visibleProfile = visibleAccount.children.first
        let visibleProfileNode = try #require(visibleProfile)

        #expect(visibleAccount.id == account.id)
        #expect(visibleProfileNode.id == profileNode.id)
        #expect(projection.autoRevealedPaths.contains(account.path))
        #expect(projection.autoRevealedPaths.contains(profileNode.path))
    }

    @Test("repeating a filter keeps every visible node identity stable")
    func repeatingFilterKeepsEveryVisibleNodeIdentityStable() throws {
        let root = try parse(#"{"outer":{"inner":{"value":"needle"}}}"#)
        let first = visibleIDs(in: TreeFilter.projection(rootNode: root, searchText: "needle").nodes)
        _ = TreeFilter.projection(rootNode: root, searchText: "need")
        let again = visibleIDs(in: TreeFilter.projection(rootNode: root, searchText: "needle").nodes)

        #expect(first == again)
    }

    @Test("a container matched by key keeps its full contents expandable")
    func containerMatchedByKeyKeepsFullContents() throws {
        let root = try parse(#"{"user":{"address":{"city":"Paris","zip":"75001"}}}"#)

        let projection = TreeFilter.projection(rootNode: root, searchText: "address")
        let user = try #require(projection.nodes.first)
        let address = try #require(user.children.first)

        #expect(address.key == "address")
        #expect(address.children.count == 2)
        #expect(!projection.autoRevealedPaths.contains(address.path))
    }

    @Test("a key match that also matches a descendant keeps the siblings of that descendant")
    func keyMatchWithDescendantMatchKeepsSiblings() throws {
        let root = try parse(#"{"address":{"city":"Paris","zip":"75001"}}"#)

        let projection = TreeFilter.projection(rootNode: root, searchText: "s")
        let address = try #require(projection.nodes.first)
        let keys = address.children.compactMap(\.key).sorted()

        #expect(address.key == "address")
        #expect(keys == ["city", "zip"])
        #expect(projection.autoRevealedPaths.contains(address.path))
    }

    @Test("a query matching nothing yields an empty projection")
    func queryMatchingNothingYieldsEmptyProjection() throws {
        let root = try parse(#"{"outer":{"inner":"value"}}"#)

        let projection = TreeFilter.projection(rootNode: root, searchText: "zzznomatch")

        #expect(projection.nodes.isEmpty)
        #expect(projection.isFiltered)
        #expect(projection.matchCount == 0)
    }

    @Test("a whitespace-only query does not empty the tree")
    func whitespaceOnlyQueryDoesNotEmptyTheTree() throws {
        let root = try parse(#"{"outer":{"inner":"value"}}"#)

        let projection = TreeFilter.projection(rootNode: root, searchText: "   ")

        #expect(projection.nodes.count == root.children.count)
        #expect(!projection.isFiltered)
    }

    @Test("matching is accent-insensitive")
    func matchingIsAccentInsensitive() throws {
        let root = try parse(#"{"name":"café"}"#)

        let projection = TreeFilter.projection(rootNode: root, searchText: "cafe")

        #expect(projection.nodes.count == 1)
    }

    @Test("a value longer than the display cap is still searchable in full")
    func longValueRemainsSearchableBeyondDisplayCap() throws {
        let padding = String(repeating: "a", count: 400)
        let root = try parse("{\"note\":\"\(padding)needle\"}")
        let note = try #require(root.children.first)

        #expect((note.displayValue as NSString).length < 400)

        let projection = TreeFilter.projection(rootNode: root, searchText: "needle")

        #expect(projection.nodes.count == 1)
    }

    @Test("a primitive root remains searchable")
    func primitiveRootRemainsSearchable() throws {
        let root = try parse("42")

        #expect(TreeFilter.projection(rootNode: root, searchText: "42").nodes.count == 1)
        #expect(TreeFilter.projection(rootNode: root, searchText: "missing").nodes.isEmpty)
    }

    @Test("filtering a near-limit tree keeps only the matching row")
    func filteringNearLimitTreeKeepsOnlyMatchingRow() throws {
        let entries = (0 ..< 4_900).map { "\"key\($0)\":\($0)" }.joined(separator: ",")
        let root = try parse("{\(entries)}")

        let projection = TreeFilter.projection(rootNode: root, searchText: "key4899")

        #expect(root.children.count == 4_900)
        #expect(projection.nodes.count == 1)
        #expect(projection.nodes.first?.key == "key4899")
    }

    @Test("a document past the node cap reports truncation")
    func documentPastNodeCapReportsTruncation() throws {
        let entries = (0 ..< 5_001).map { "\"key\($0)\":\($0)" }.joined(separator: ",")
        let root = try parse("{\(entries)}")

        let info = TreeFilter.documentInfo(rootNode: root)

        #expect(info.isTruncated)
    }

    @Test("a document inside the node cap reports no truncation")
    func documentInsideNodeCapReportsNoTruncation() throws {
        let root = try parse(#"{"outer":{"inner":"value"}}"#)

        #expect(!TreeFilter.documentInfo(rootNode: root).isTruncated)
    }

    @Test("document info collects every container and defaults to the top level")
    func documentInfoCollectsContainersAndTopLevelDefaults() throws {
        let root = try parse(#"{"outer":{"inner":{"leaf":1}},"flat":2}"#)
        let outer = try #require(root.children.first)
        let inner = try #require(outer.children.first)

        let info = TreeFilter.documentInfo(rootNode: root)

        #expect(info.allContainerPaths.contains(outer.path))
        #expect(info.allContainerPaths.contains(inner.path))
        #expect(info.defaultExpandedPaths == [outer.path])
    }

    @Test("container paths survive a re-parse of the same document")
    func containerPathsSurviveReparse() throws {
        let json = #"{"outer":{"inner":{"leaf":1}}}"#
        let first = try parse(json)
        let second = try parse(json)

        let firstInfo = TreeFilter.documentInfo(rootNode: first)
        let secondInfo = TreeFilter.documentInfo(rootNode: second)

        #expect(firstInfo.allContainerPaths == secondInfo.allContainerPaths)
        #expect(firstInfo.allContainerPaths.count == 3)
        #expect(first.children.first?.id != second.children.first?.id)
    }

    @Test("the PHP tree filters through the same implementation")
    func phpTreeFiltersThroughTheSameImplementation() throws {
        let value = try #require(PhpSerializeParser.parse(#"a:1:{s:4:"name";s:5:"café";}"#))
        let root = PhpTreeBuilder.build(from: value, formats: .english)

        #expect(TreeFilter.projection(rootNode: root, searchText: "name").nodes.count == 1)
        #expect(TreeFilter.projection(rootNode: root, searchText: "cafe").nodes.count == 1)
    }

    @Test("a PHP string longer than the display cap is searchable in full")
    func phpLongStringRemainsSearchable() throws {
        let padding = String(repeating: "a", count: 200)
        let payload = "\(padding)needle"
        let serialized = "a:1:{s:4:\"note\";s:\(payload.utf8.count):\"\(payload)\";}"
        let value = try #require(PhpSerializeParser.parse(serialized))
        let root = PhpTreeBuilder.build(from: value, formats: .english)
        let note = try #require(root.children.first)

        #expect((note.displayValue as NSString).length < 200)
        #expect(TreeFilter.projection(rootNode: root, searchText: "needle").nodes.count == 1)
    }

    @Test("copying a JSON container yields the subtree, not its summary")
    func copyingJsonContainerYieldsSubtree() throws {
        let root = try parse(#"{"outer":{"a":1,"b":"two"}}"#)
        let outer = try #require(root.children.first)

        #expect(outer.displayValue == "{2 keys}")
        #expect(outer.copyableValue == #"{"a":1,"b":"two"}"#)
    }

    @Test("copying a truncated JSON string yields the whole value")
    func copyingTruncatedStringYieldsWholeValue() throws {
        let padding = String(repeating: "a", count: 400)
        let root = try parse("{\"note\":\"\(padding)\"}")
        let note = try #require(root.children.first)

        #expect((note.copyableValue as NSString).length == 400)
    }

    @Test("a JSON array index is not a searchable key")
    func jsonArrayIndexIsNotSearchable() throws {
        let root = try parse(#"[{"city":"Hue"},{"zip":"10001"},{"city":"Hanoi"}]"#)

        let projection = TreeFilter.projection(rootNode: root, searchText: "1")
        let element = try #require(projection.nodes.first)

        #expect(projection.matchCount == 1)
        #expect(projection.nodes.count == 1)
        #expect(element.key == "[1]")
        #expect(element.children.map(\.key) == ["zip"])
        #expect(TreeFilter.projection(rootNode: root, searchText: "[0]").nodes.isEmpty)
    }

    @Test("a count summary is not searchable")
    func countSummaryIsNotSearchable() throws {
        let root = try parse(#"{"outer":{"a":1,"b":2},"list":[1,2,3]}"#)

        #expect(TreeFilter.projection(rootNode: root, searchText: "keys").nodes.isEmpty)
        #expect(TreeFilter.projection(rootNode: root, searchText: "2 k").nodes.isEmpty)
        #expect(TreeFilter.projection(rootNode: root, searchText: "items").nodes.isEmpty)
    }

    @Test("the truncation marker is not searchable")
    func truncationMarkerIsNotSearchable() throws {
        let entries = (0 ..< 5_001).map { "\"key\($0)\":\($0)" }.joined(separator: ",")
        let root = try parse("{\(entries)}")

        #expect(root.children.last?.isTruncationMarker == true)
        #expect(TreeFilter.projection(rootNode: root, searchText: "more").nodes.isEmpty)
    }

    @Test("a JSON null is still found by its literal")
    func jsonNullIsSearchable() throws {
        let root = try parse(#"{"gone":null,"here":1}"#)

        #expect(TreeFilter.projection(rootNode: root, searchText: "null").nodes.map(\.key) == ["gone"])
    }

    @Test("a PHP integer key is a stored key and stays searchable")
    func phpIntegerKeyIsSearchable() {
        let root = PhpTreeBuilder.build(
            from: .array([
                PhpKeyValue(key: .int(404), value: .string("missing")),
                PhpKeyValue(key: .int(500), value: .string("broken"))
            ]),
            formats: .english
        )

        let projection = TreeFilter.projection(rootNode: root, searchText: "404")

        #expect(projection.nodes.map(\.key) == ["[404]"])
    }

    @Test("a PHP class name is searchable and its property count is not")
    func phpClassNameIsSearchable() {
        let basket = PhpValue.object(
            className: "Basket",
            properties: [PhpProperty(name: "sku", visibility: .publicVisibility, value: .string("A-1"))]
        )
        let root = PhpTreeBuilder.build(
            from: .array([PhpKeyValue(key: .string("entry"), value: basket)]),
            formats: .english
        )

        #expect(TreeFilter.projection(rootNode: root, searchText: "Basket").matchCount == 1)
        #expect(TreeFilter.projection(rootNode: root, searchText: "property").nodes.isEmpty)
    }

    @Test("a PHP array summary is not searchable")
    func phpArraySummaryIsNotSearchable() {
        let list = PhpValue.array([PhpKeyValue(key: .int(0), value: .string("x"))])
        let root = PhpTreeBuilder.build(
            from: .array([PhpKeyValue(key: .string("list"), value: list)]),
            formats: .english
        )

        #expect(TreeFilter.projection(rootNode: root, searchText: "item").nodes.isEmpty)
    }

    @Test("a PHP serializable node is searched in its class name and its whole payload")
    func phpSerializableIsSearchedInFull() {
        let payload = String(repeating: "q", count: 150) + "NEEDLE"
        let root = PhpTreeBuilder.build(
            from: .array([
                PhpKeyValue(key: .string("blob"), value: .serializable(className: "ArrayObject", rawPayload: payload))
            ]),
            formats: .english
        )

        #expect(TreeFilter.projection(rootNode: root, searchText: "NEEDLE").matchCount == 1)
        #expect(TreeFilter.projection(rootNode: root, searchText: "ArrayObject").matchCount == 1)
    }

    private func parse(_ json: String) throws -> JSONTreeNode {
        try JSONTreeParser.parse(json, formats: .english).get()
    }

    private func visibleIDs(in nodes: [JSONTreeNode]) -> [UUID] {
        nodes.flatMap { node in [node.id] + visibleIDs(in: node.children) }
    }
}

struct TreeNodePathTests {
    @Test("duplicate keys get different paths, and only the duplicate carries an occurrence")
    func duplicateKeysGetDifferentPaths() throws {
        let root = try parse(#"{"id":1,"name":"a","id":2}"#)

        #expect(root.children.map(\.path.lastComponent) == [
            .key("id", occurrence: 0),
            .key("name", occurrence: 0),
            .key("id", occurrence: 1)
        ])
        #expect(root.children.map(\.keyPath) == ["$.id", "$.name", "$.id"])
    }

    @Test("a dotted key and a nested key get different paths")
    func dottedAndNestedKeysGetDifferentPaths() throws {
        let root = try parse(#"{"a.b":{"x":1},"a":{"b":{"y":2}},"k[0]":{"z":3},"k":[{"w":4}]}"#)

        let paths = allNodes(in: root).map(\.path)

        #expect(Set(paths).count == paths.count)
    }

    @Test("an array element is addressed by its index")
    func arrayElementIsAddressedByIndex() throws {
        let root = try parse(#"{"list":["a","b"]}"#)
        let list = try #require(root.children.first)

        #expect(list.children.map(\.path.components) == [
            [.key("list", occurrence: 0), .index(0)],
            [.key("list", occurrence: 0), .index(1)]
        ])
        #expect(root.path == .root)
        #expect(root.path.components.isEmpty)
    }

    @Test("every truncation marker has its own path")
    func truncationMarkersHaveTheirOwnPaths() throws {
        let elements = (0 ..< 5_001).map(String.init).joined(separator: ",")
        let root = try parse("{\"a\":[\(elements)],\"b\":1}")

        let nodes = allNodes(in: root)
        let markers = nodes.filter(\.isTruncationMarker)

        #expect(markers.count == 2)
        #expect(Set(markers.map(\.path)).count == 2)
        #expect(Set(nodes.map(\.path)).count == nodes.count)
        #expect(markers.allSatisfy { $0.path.lastComponent == .truncationMarker })
    }

    @Test("paths are equal across two parses and node ids are not")
    func pathsAreEqualAcrossParses() throws {
        let json = #"{"rows":[{"id":1,"id":2},{"tags":["x","y"]}],"meta":null}"#
        let first = allNodes(in: try parse(json))
        let second = allNodes(in: try parse(json))

        #expect(first.map(\.path) == second.map(\.path))
        #expect(Set(first.map(\.path)) == Set(second.map(\.path)))
        #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
    }

    @Test("a path knows its ancestors")
    func pathKnowsItsAncestors() throws {
        let root = try parse(#"{"a":{"b":{"c":1}},"d":2}"#)
        let a = try #require(root.children.first)
        let b = try #require(a.children.first)
        let c = try #require(b.children.first)
        let d = try #require(root.children.last)

        #expect(c.path.hasAncestor(in: [a.path]))
        #expect(c.path.hasAncestor(in: [b.path, d.path]))
        #expect(!c.path.hasAncestor(in: [c.path, d.path]))
        #expect(!a.path.hasAncestor(in: [b.path]))
        #expect(c.path.parent == b.path)
        #expect(c.path.depth == 3)
        #expect(TreeNodePath.root.parent == nil)
    }

    @Test("a PHP integer key and the same digits as a string key get different paths")
    func phpIntegerAndStringKeysGetDifferentPaths() {
        let root = PhpTreeBuilder.build(
            from: .array([
                PhpKeyValue(key: .int(5), value: .string("a")),
                PhpKeyValue(key: .string("5"), value: .string("b")),
                PhpKeyValue(key: .int(5), value: .string("c"))
            ]),
            formats: .english
        )

        #expect(root.children.map(\.path.lastComponent) == [
            .integerKey(5, occurrence: 0),
            .key("5", occurrence: 0),
            .integerKey(5, occurrence: 1)
        ])
    }

    @Test("two PHP properties with one name get different paths")
    func phpPropertiesWithOneNameGetDifferentPaths() {
        let root = PhpTreeBuilder.build(
            from: .object(
                className: "Cart",
                properties: [
                    PhpProperty(name: "total", visibility: .privateVisibility(className: "Cart"), value: .int(1)),
                    PhpProperty(name: "total", visibility: .protectedVisibility, value: .int(2))
                ]
            ),
            formats: .english
        )

        #expect(Set(root.children.map(\.path)).count == 2)
    }

    private func parse(_ json: String) throws -> JSONTreeNode {
        try JSONTreeParser.parse(json, formats: .english).get()
    }

    private func allNodes(in node: JSONTreeNode) -> [JSONTreeNode] {
        [node] + node.children.flatMap { allNodes(in: $0) }
    }
}

@MainActor
struct TreeProjectionCacheTests {
    @Test("repeated reads for the same document and query compute once")
    func repeatedReadsComputeOnce() throws {
        let root = try JSONTreeParser.parse(#"{"outer":{"inner":"needle"}}"#).get()
        let cache = TreeProjectionCache<JSONTreeNode>()

        for _ in 0 ..< 10 {
            _ = cache.projection(for: root, searchText: "needle")
            _ = cache.documentInfo(for: root)
        }

        #expect(cache.projectionComputations == 1)
        #expect(cache.documentComputations == 1)
    }

    @Test("a changed query recomputes the projection but not the document")
    func changedQueryRecomputesProjectionOnly() throws {
        let root = try JSONTreeParser.parse(#"{"outer":{"inner":"needle"}}"#).get()
        let cache = TreeProjectionCache<JSONTreeNode>()

        _ = cache.documentInfo(for: root)
        _ = cache.projection(for: root, searchText: "n")
        _ = cache.projection(for: root, searchText: "ne")
        _ = cache.documentInfo(for: root)

        #expect(cache.projectionComputations == 2)
        #expect(cache.documentComputations == 1)
    }

    @Test("a replaced document recomputes both")
    func replacedDocumentRecomputesBoth() throws {
        let first = try JSONTreeParser.parse(#"{"outer":{"inner":"needle"}}"#).get()
        let second = try JSONTreeParser.parse(#"{"outer":{"inner":"needle"}}"#).get()
        let cache = TreeProjectionCache<JSONTreeNode>()

        _ = cache.projection(for: first, searchText: "needle")
        _ = cache.documentInfo(for: first)
        _ = cache.projection(for: second, searchText: "needle")
        _ = cache.documentInfo(for: second)

        #expect(cache.projectionComputations == 2)
        #expect(cache.documentComputations == 2)
    }

    @Test("the source node of a filtered container is the whole container")
    func sourceNodeOfFilteredContainerIsWhole() throws {
        let json = #"{"invoice":{"no":"INV-9","lines":[{"sku":"apple","n":2},{"sku":"pear","n":5}],"paid":false}}"#
        let root = try JSONTreeParser.parse(json, formats: .english).get()
        let cache = TreeProjectionCache<JSONTreeNode>()

        let projected = try #require(cache.projection(for: root, searchText: "pear").nodes.first)
        let source = try #require(cache.sourceNode(at: projected.path, in: root))

        #expect(projected.copyableValue == #"{"lines":[{"sku":"pear"}]}"#)
        #expect(source.id == projected.id)
        #expect(
            source.copyableValue
                == #"{"no":"INV-9","lines":[{"sku":"apple","n":2},{"sku":"pear","n":5}],"paid":false}"#
        )
    }

    @Test("source lookups index a document once and again when it is replaced")
    func sourceLookupsIndexOncePerDocument() throws {
        let json = #"{"outer":{"inner":"needle"}}"#
        let first = try JSONTreeParser.parse(json, formats: .english).get()
        let second = try JSONTreeParser.parse(json, formats: .english).get()
        let cache = TreeProjectionCache<JSONTreeNode>()
        let inner = try #require(first.children.first?.children.first)

        for _ in 0 ..< 10 {
            _ = cache.sourceNode(at: inner.path, in: first)
        }
        #expect(cache.sourceIndexComputations == 1)

        let replaced = try #require(cache.sourceNode(at: inner.path, in: second))
        #expect(cache.sourceIndexComputations == 2)
        #expect(replaced.id != inner.id)
        #expect(replaced.rawValue == "needle")
    }

    @Test("the root and an unknown path resolve as the document has them")
    func rootAndUnknownPathsResolve() throws {
        let root = try JSONTreeParser.parse(#"{"a":1}"#, formats: .english).get()
        let cache = TreeProjectionCache<JSONTreeNode>()

        #expect(cache.sourceNode(at: .root, in: root)?.id == root.id)
        #expect(cache.sourceNode(at: TreeNodePath.root.appending(.key("missing", occurrence: 0)), in: root) == nil)
        #expect(cache.sourceNode(at: TreeNodePath.root.appending(.key("a", occurrence: 1)), in: root) == nil)
    }
}

struct TreeDisclosureStateTests {
    private static let top = TreeNodePath.root.appending(.key("top", occurrence: 0))
    private static let match = TreeNodePath.root.appending(.key("match", occurrence: 0))
    private static let other = TreeNodePath.root.appending(.key("other", occurrence: 0))

    private let auto: Set<TreeNodePath> = [match]
    private let defaults: Set<TreeNodePath> = [top]
    private let containers: Set<TreeNodePath> = [top, match, other]

    @Test("top-level containers are expanded by default")
    func topLevelContainersExpandByDefault() {
        let state = TreeDisclosureState()

        #expect(isExpanded(state, Self.top, filtered: false))
        #expect(!isExpanded(state, Self.other, filtered: false))
    }

    @Test("a filter reveals matching ancestors without touching saved intent")
    func filterRevealsMatchingAncestors() {
        let state = TreeDisclosureState()

        #expect(isExpanded(state, Self.match, filtered: true))
        #expect(!isExpanded(state, Self.match, filtered: false))
    }

    @Test("collapse all before a search does not veto the search reveal")
    func collapseAllBeforeSearchDoesNotVetoReveal() {
        var state = TreeDisclosureState()
        state.collapseAll(containerPaths: containers, isFiltered: false)

        #expect(!isExpanded(state, Self.top, filtered: false))
        #expect(isExpanded(state, Self.match, filtered: true))
    }

    @Test("a collapse made during a search survives the next keystroke")
    func collapseDuringSearchSurvivesNextKeystroke() {
        var state = TreeDisclosureState()
        state.setExpanded(false, path: Self.match, isFiltered: true)

        #expect(!isExpanded(state, Self.match, filtered: true))
    }

    @Test("clearing the filter restores the pre-search layout")
    func clearingFilterRestoresPreSearchLayout() {
        var state = TreeDisclosureState()
        state.setExpanded(true, path: Self.other, isFiltered: false)
        state.expandAll(containerPaths: containers, isFiltered: true)
        state.endFiltering()

        #expect(isExpanded(state, Self.other, filtered: false))
        #expect(!isExpanded(state, Self.match, filtered: false))
    }

    @Test("expand all outside a search persists across filtering")
    func expandAllOutsideSearchPersists() {
        var state = TreeDisclosureState()
        state.expandAll(containerPaths: containers, isFiltered: false)
        state.endFiltering()

        #expect(isExpanded(state, Self.other, filtered: false))
        #expect(isExpanded(state, Self.match, filtered: false))
    }

    @Test("an expansion made during a search does not leak into saved intent")
    func inSearchExpansionDoesNotLeak() {
        var state = TreeDisclosureState()
        state.setExpanded(true, path: Self.other, isFiltered: true)

        #expect(isExpanded(state, Self.other, filtered: true))

        state.endFiltering()

        #expect(!isExpanded(state, Self.other, filtered: false))
    }

    @Test("a collapse outside a search persists")
    func collapseOutsideSearchPersists() {
        var state = TreeDisclosureState()
        state.setExpanded(false, path: Self.top, isFiltered: false)

        #expect(!isExpanded(state, Self.top, filtered: false))
    }

    @Test("a duplicate key collapses on its own")
    func duplicateKeyCollapsesOnItsOwn() {
        let firstCopy = TreeNodePath.root.appending(.key("dup", occurrence: 0))
        let secondCopy = TreeNodePath.root.appending(.key("dup", occurrence: 1))
        var state = TreeDisclosureState()
        state.expandAll(containerPaths: [firstCopy, secondCopy], isFiltered: false)
        state.setExpanded(false, path: secondCopy, isFiltered: false)

        #expect(isExpanded(state, firstCopy, filtered: false))
        #expect(!isExpanded(state, secondCopy, filtered: false))
    }

    private func isExpanded(_ state: TreeDisclosureState, _ path: TreeNodePath, filtered: Bool) -> Bool {
        state.isExpanded(
            path,
            autoRevealedPaths: auto,
            defaultExpandedPaths: defaults,
            isFiltered: filtered
        )
    }
}

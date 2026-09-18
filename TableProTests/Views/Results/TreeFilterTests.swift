import Foundation
import Testing

@testable import TablePro

@Suite("TreeFilter")
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
        #expect(projection.autoRevealedKeyPaths.contains(account.keyPath))
        #expect(projection.autoRevealedKeyPaths.contains(profileNode.keyPath))
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
        #expect(!projection.autoRevealedKeyPaths.contains(address.keyPath))
    }

    @Test("a key match that also matches a descendant keeps the siblings of that descendant")
    func keyMatchWithDescendantMatchKeepsSiblings() throws {
        let root = try parse(#"{"address":{"city":"Paris","zip":"75001"}}"#)

        let projection = TreeFilter.projection(rootNode: root, searchText: "s")
        let address = try #require(projection.nodes.first)
        let keys = address.children.compactMap(\.key).sorted()

        #expect(address.key == "address")
        #expect(keys == ["city", "zip"])
        #expect(projection.autoRevealedKeyPaths.contains(address.keyPath))
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

        #expect(info.allContainerKeyPaths.contains(outer.keyPath))
        #expect(info.allContainerKeyPaths.contains(inner.keyPath))
        #expect(info.defaultExpandedKeyPaths == [outer.keyPath])
    }

    @Test("key paths survive a re-parse of the same document")
    func keyPathsSurviveReparse() throws {
        let json = #"{"outer":{"inner":{"leaf":1}}}"#
        let first = try parse(json)
        let second = try parse(json)

        let firstInfo = TreeFilter.documentInfo(rootNode: first)
        let secondInfo = TreeFilter.documentInfo(rootNode: second)

        #expect(firstInfo.allContainerKeyPaths == secondInfo.allContainerKeyPaths)
        #expect(first.children.first?.id != second.children.first?.id)
    }

    @Test("the PHP tree filters through the same implementation")
    func phpTreeFiltersThroughTheSameImplementation() throws {
        let value = try #require(PhpSerializeParser.parse(#"a:1:{s:4:"name";s:5:"café";}"#))
        let root = PhpTreeBuilder.build(from: value)

        #expect(TreeFilter.projection(rootNode: root, searchText: "name").nodes.count == 1)
        #expect(TreeFilter.projection(rootNode: root, searchText: "cafe").nodes.count == 1)
    }

    @Test("a PHP string longer than the display cap is searchable in full")
    func phpLongStringRemainsSearchable() throws {
        let padding = String(repeating: "a", count: 200)
        let payload = "\(padding)needle"
        let serialized = "a:1:{s:4:\"note\";s:\(payload.utf8.count):\"\(payload)\";}"
        let value = try #require(PhpSerializeParser.parse(serialized))
        let root = PhpTreeBuilder.build(from: value)
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

    private func parse(_ json: String) throws -> JSONTreeNode {
        try JSONTreeParser.parse(json).get()
    }

    private func visibleIDs(in nodes: [JSONTreeNode]) -> [UUID] {
        nodes.flatMap { node in [node.id] + visibleIDs(in: node.children) }
    }
}

@Suite("TreeProjectionCache")
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
}

@Suite("TreeDisclosureState")
struct TreeDisclosureStateTests {
    private let auto: Set<String> = ["$.match"]
    private let defaults: Set<String> = ["$.top"]
    private let containers: Set<String> = ["$.top", "$.match", "$.other"]

    @Test("top-level containers are expanded by default")
    func topLevelContainersExpandByDefault() {
        let state = TreeDisclosureState()

        #expect(isExpanded(state, "$.top", filtered: false))
        #expect(!isExpanded(state, "$.other", filtered: false))
    }

    @Test("a filter reveals matching ancestors without touching saved intent")
    func filterRevealsMatchingAncestors() {
        let state = TreeDisclosureState()

        #expect(isExpanded(state, "$.match", filtered: true))
        #expect(!isExpanded(state, "$.match", filtered: false))
    }

    @Test("collapse all before a search does not veto the search reveal")
    func collapseAllBeforeSearchDoesNotVetoReveal() {
        var state = TreeDisclosureState()
        state.collapseAll(containerKeyPaths: containers, isFiltered: false)

        #expect(!isExpanded(state, "$.top", filtered: false))
        #expect(isExpanded(state, "$.match", filtered: true))
    }

    @Test("a collapse made during a search survives the next keystroke")
    func collapseDuringSearchSurvivesNextKeystroke() {
        var state = TreeDisclosureState()
        state.setExpanded(false, keyPath: "$.match", isFiltered: true)

        #expect(!isExpanded(state, "$.match", filtered: true))
    }

    @Test("clearing the filter restores the pre-search layout")
    func clearingFilterRestoresPreSearchLayout() {
        var state = TreeDisclosureState()
        state.setExpanded(true, keyPath: "$.other", isFiltered: false)
        state.expandAll(containerKeyPaths: containers, isFiltered: true)
        state.endFiltering()

        #expect(isExpanded(state, "$.other", filtered: false))
        #expect(!isExpanded(state, "$.match", filtered: false))
    }

    @Test("expand all outside a search persists across filtering")
    func expandAllOutsideSearchPersists() {
        var state = TreeDisclosureState()
        state.expandAll(containerKeyPaths: containers, isFiltered: false)
        state.endFiltering()

        #expect(isExpanded(state, "$.other", filtered: false))
        #expect(isExpanded(state, "$.match", filtered: false))
    }

    @Test("an expansion made during a search does not leak into saved intent")
    func inSearchExpansionDoesNotLeak() {
        var state = TreeDisclosureState()
        state.setExpanded(true, keyPath: "$.other", isFiltered: true)

        #expect(isExpanded(state, "$.other", filtered: true))

        state.endFiltering()

        #expect(!isExpanded(state, "$.other", filtered: false))
    }

    @Test("a collapse outside a search persists")
    func collapseOutsideSearchPersists() {
        var state = TreeDisclosureState()
        state.setExpanded(false, keyPath: "$.top", isFiltered: false)

        #expect(!isExpanded(state, "$.top", filtered: false))
    }

    private func isExpanded(_ state: TreeDisclosureState, _ keyPath: String, filtered: Bool) -> Bool {
        state.isExpanded(
            keyPath,
            autoRevealedKeyPaths: auto,
            defaultExpandedKeyPaths: defaults,
            isFiltered: filtered
        )
    }
}

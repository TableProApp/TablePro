import Foundation
import Testing

@testable import TablePro

@Suite("JSONTreeViewState")
struct JSONTreeViewStateTests {
    @Test("nested matches preserve identities and reveal their ancestors")
    func nestedMatchesPreserveIdentitiesAndRevealAncestors() throws {
        let root = try parse(
            """
            {
              "account": {
                "profile": {
                  "city": "needle"
                }
              }
            }
            """
        )
        let account = try #require(root.children.first)
        let profile = try #require(account.children.first)
        let city = try #require(profile.children.first)

        let state = JSONTreeViewState(rootNode: root, searchText: "needle")
        let visibleAccount = try #require(state.visibleNodes.first)
        let visibleProfile = try #require(visibleAccount.children.first)
        let visibleCity = try #require(visibleProfile.children.first)

        #expect(visibleAccount.id == account.id)
        #expect(visibleProfile.id == profile.id)
        #expect(visibleCity.id == city.id)
        #expect(state.expandedNodeIDs.contains(account.id))
        #expect(state.expandedNodeIDs.contains(profile.id))
    }

    @Test("repeating a filter keeps every visible node identity stable")
    func repeatingFilterKeepsEveryVisibleNodeIdentityStable() throws {
        let root = try parse(#"{"outer":{"inner":{"value":"needle"}}}"#)
        var state = JSONTreeViewState(rootNode: root, searchText: "needle")
        let firstIDs = visibleIDs(in: state.visibleNodes)

        state.update(searchText: "need")
        state.update(searchText: "needle")

        #expect(visibleIDs(in: state.visibleNodes) == firstIDs)
    }

    @Test("clearing a filter restores the disclosure state from before search")
    func clearingFilterRestoresPreviousDisclosureState() throws {
        let root = try parse(#"{"outer":{"inner":{"value":"needle"}}}"#)
        let outer = try #require(root.children.first)
        let inner = try #require(outer.children.first)
        var state = JSONTreeViewState(rootNode: root, searchText: "")

        state.collapseAll()
        state.update(searchText: "needle")

        #expect(state.expandedNodeIDs.contains(outer.id))
        #expect(state.expandedNodeIDs.contains(inner.id))

        state.update(searchText: "")

        #expect(state.expandedNodeIDs.isEmpty)
    }

    @Test("replacing the root discards identities and disclosure state from the old tree")
    func replacingRootDiscardsOldTreeState() throws {
        let originalRoot = try parse(#"{"outer":{"value":"needle"}}"#)
        let replacementRoot = try parse(#"{"outer":{"value":"needle"}}"#)
        let oldOuter = try #require(originalRoot.children.first)
        let newOuter = try #require(replacementRoot.children.first)
        var state = JSONTreeViewState(rootNode: originalRoot, searchText: "needle")

        state.update(rootNode: replacementRoot)

        let visibleOuter = try #require(state.visibleNodes.first)
        #expect(visibleOuter.id == newOuter.id)
        #expect(visibleOuter.id != oldOuter.id)
        #expect(!state.expandedNodeIDs.contains(oldOuter.id))
        #expect(state.expandedNodeIDs.contains(newOuter.id))
    }

    @Test("a matching container does not expose unrelated descendants")
    func matchingContainerDoesNotExposeUnrelatedDescendants() throws {
        let root = try parse(#"{"matching-container":{"unrelated":"value"}}"#)
        let container = try #require(root.children.first)

        let state = JSONTreeViewState(rootNode: root, searchText: "matching")
        let visibleContainer = try #require(state.visibleNodes.first)

        #expect(visibleContainer.id == container.id)
        #expect(visibleContainer.children.isEmpty)
    }

    @Test("a primitive root remains searchable")
    func primitiveRootRemainsSearchable() throws {
        let root = try parse("42")
        let matchingState = JSONTreeViewState(rootNode: root, searchText: "42")
        let missingState = JSONTreeViewState(rootNode: root, searchText: "missing")

        #expect(matchingState.visibleNodes.first?.id == root.id)
        #expect(missingState.visibleNodes.isEmpty)
    }

    @Test("filtering a near-limit tree keeps only the matching row")
    func filteringNearLimitTreeKeepsOnlyMatchingRow() throws {
        let entries = (0..<4_900)
            .map { "\"key\($0)\":\($0)" }
            .joined(separator: ",")
        let root = try parse("{\(entries)}")

        let state = JSONTreeViewState(rootNode: root, searchText: "key4899")

        #expect(root.children.count == 4_900)
        #expect(state.visibleNodes.count == 1)
        #expect(state.visibleNodes.first?.key == "key4899")
    }

    private func parse(_ json: String) throws -> JSONTreeNode {
        try JSONTreeParser.parse(json).get()
    }

    private func visibleIDs(in nodes: [JSONTreeNode]) -> [UUID] {
        nodes.flatMap { node in
            [node.id] + visibleIDs(in: node.children)
        }
    }
}

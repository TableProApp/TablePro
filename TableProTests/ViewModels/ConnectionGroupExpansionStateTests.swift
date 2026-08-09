//
//  ConnectionGroupExpansionStateTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Connection group expansion state")
@MainActor
struct ConnectionGroupExpansionStateTests {
    private static let storageKey = "com.TablePro.expandedGroupIds"
    private static let legacyCollapsedKey = "com.TablePro.collapsedGroupIds"

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "com.TablePro.tests.groupExpansion.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    private func makeGroup(_ name: String, parentId: UUID? = nil) -> ConnectionGroup {
        ConnectionGroup(name: name, parentId: parentId)
    }

    @Test("A fresh store has nothing expanded")
    func emptyByDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ConnectionGroupExpansionState(defaults: defaults).expandedGroupIds.isEmpty)
    }

    @Test("Expanding a group round-trips through UserDefaults")
    func expansionRoundTrips() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = ConnectionGroupExpansionState(defaults: defaults)
        let group = makeGroup("Acme")
        state.setExpanded(group.id, expanded: true)
        #expect(state.isExpanded(group.id))

        let reloaded = ConnectionGroupExpansionState(defaults: defaults)
        #expect(reloaded.isExpanded(group.id))
    }

    @Test("Collapsing a group removes it from the stored arrangement")
    func collapseRemoves() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = ConnectionGroupExpansionState(defaults: defaults)
        let group = makeGroup("Acme")
        state.setExpanded(group.id, expanded: true)
        state.setExpanded(group.id, expanded: false)

        #expect(!ConnectionGroupExpansionState(defaults: defaults).isExpanded(group.id))
    }

    @Test("An arrangement the welcome window already wrote is read unchanged")
    func readsExistingWelcomeArrangement() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let existing = [UUID(), UUID()]
        defaults.set(existing.map(\.uuidString), forKey: Self.storageKey)

        let state = ConnectionGroupExpansionState(defaults: defaults)
        #expect(state.expandedGroupIds == Set(existing))
    }

    @Test("A stored arrangement leaves the retired collapsed-ids key alone")
    func storedArrangementKeepsLegacyKey() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set([UUID().uuidString], forKey: Self.storageKey)
        defaults.set(["stale"], forKey: Self.legacyCollapsedKey)

        _ = ConnectionGroupExpansionState(defaults: defaults)
        #expect(defaults.stringArray(forKey: Self.legacyCollapsedKey) == ["stale"])
    }

    @Test("With nothing stored, the retired collapsed-ids key is cleared")
    func emptyArrangementClearsLegacyKey() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["stale"], forKey: Self.legacyCollapsedKey)

        _ = ConnectionGroupExpansionState(defaults: defaults)
        #expect(defaults.stringArray(forKey: Self.legacyCollapsedKey) == nil)
    }

    @Test("A first run expands every group, so a new install shows its groups open")
    func seedsEveryGroupOnFirstRun() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = ConnectionGroupExpansionState(defaults: defaults)
        let groups = [makeGroup("Acme"), makeGroup("Side projects")]
        state.expandAllIfNeeded(groups: groups)

        #expect(state.expandedGroupIds == Set(groups.map(\.id)))
    }

    @Test("Seeding never reopens groups the user collapsed")
    func seedingLeavesAnExistingArrangementAlone() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = ConnectionGroupExpansionState(defaults: defaults)
        let kept = makeGroup("Acme")
        let collapsed = makeGroup("Side projects")
        state.setExpanded(kept.id, expanded: true)

        state.expandAllIfNeeded(groups: [kept, collapsed])

        #expect(state.expandedGroupIds == [kept.id])
    }

    @Test("Seeding with no groups leaves the arrangement empty")
    func seedingWithoutGroupsStoresNothing() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = ConnectionGroupExpansionState(defaults: defaults)
        state.expandAllIfNeeded(groups: [])

        #expect(state.expandedGroupIds.isEmpty)
    }

    @Test("Expand and collapse apply to a whole subtree at once")
    func expandAndCollapseSubtree() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = ConnectionGroupExpansionState(defaults: defaults)
        let parent = makeGroup("Acme")
        let child = makeGroup("Environments", parentId: parent.id)
        let unrelated = makeGroup("Side projects")
        state.setExpanded(unrelated.id, expanded: true)

        state.expand([parent.id, child.id])
        #expect(state.expandedGroupIds == [parent.id, child.id, unrelated.id])

        state.collapse([parent.id, child.id])
        #expect(state.expandedGroupIds == [unrelated.id])
    }

    @Test("Setting a group to the state it already has writes nothing")
    func redundantSetIsIgnored() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = ConnectionGroupExpansionState(defaults: defaults)
        let group = makeGroup("Acme")
        state.setExpanded(group.id, expanded: true)
        let written = defaults.stringArray(forKey: Self.storageKey)

        state.setExpanded(group.id, expanded: true)

        #expect(defaults.stringArray(forKey: Self.storageKey) == written)
    }
}

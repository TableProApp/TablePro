//
//  GroupMenuEntriesTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct GroupMenuEntriesTests {
    private func group(
        _ name: String,
        parent: ConnectionGroup? = nil,
        color: ConnectionColor = .none,
        iconName: String? = nil
    ) -> ConnectionGroup {
        ConnectionGroup(name: name, color: color, iconName: iconName, parentId: parent?.id)
    }

    @Test("The uncategorised entry comes first and carries no identifier")
    func noneComesFirst() {
        let entries = GroupMenuEntries.forConnection(groups: [], noneTitle: "None")
        #expect(entries.count == 1)
        #expect(entries[0].id == nil)
        #expect(entries[0].title == "None")
        #expect(entries[0].hasSeparatorAbove == false)
    }

    /// Depth is carried as a menu indentation level, which is what `NSMenuItem` understands.
    /// Expressing it as padding or as leading spaces in the title both got discarded.
    @Test("Nesting is reported as an indentation level")
    func nestingBecomesIndentation() {
        let root = group("Prod")
        let child = group("EU", parent: root)
        let grandchild = group("Read replica", parent: child)
        let entries = GroupMenuEntries.forConnection(
            groups: [root, child, grandchild],
            noneTitle: "None"
        )
        #expect(entries.map(\.title) == ["None", "Prod", "EU", "Read replica"])
        #expect(entries.map(\.indentationLevel) == [0, 0, 1, 2])
    }

    @Test("A separator sits between the uncategorised entry and the groups")
    func separatorSitsAboveFirstGroup() {
        let root = group("Prod")
        let entries = GroupMenuEntries.forConnection(groups: [root], noneTitle: "None")
        #expect(entries.filter(\.hasSeparatorAbove).map(\.title) == ["Prod"])
    }

    @Test("A group's colour rides along with its entry")
    func colourIsCarried() {
        let root = group("Prod", color: .red)
        let entries = GroupMenuEntries.forConnection(groups: [root], noneTitle: "None")
        #expect(entries.last?.color == .red)
    }

    @Test("A group's icon rides along with its entry")
    func iconIsCarried() {
        let root = group("Prod", iconName: "server.rack")
        let entries = GroupMenuEntries.forConnection(groups: [root], noneTitle: "None")
        #expect(entries.last?.iconName == "server.rack")
    }

    /// Offering the group itself or anything under it would let Save build a cycle.
    @Test("Moving a group never offers the group or its descendants as the parent")
    func movingLeavesOutTheGroupsSubtree() {
        let prod = group("Prod")
        let europe = group("EU", parent: prod)
        let replica = group("Replica", parent: europe)
        let staging = group("Staging")
        let entries = GroupMenuEntries.forMoving(
            groupId: europe.id,
            groups: [prod, europe, replica, staging],
            noneTitle: "None"
        )
        #expect(Set(entries.map(\.title)) == ["None", "Prod", "Staging"])
    }

    @Test("Moving a group dims a parent that would push its subtree past the nesting limit")
    func movingDimsParentsPastTheLimit() {
        let a = group("A")
        let b = group("B", parent: a)
        let c = group("C", parent: b)
        let moving = group("Moving")
        let child = group("Child", parent: moving)
        let entries = GroupMenuEntries.forMoving(
            groupId: moving.id,
            groups: [a, b, c, moving, child],
            noneTitle: "None"
        )
        let byTitle = Dictionary(uniqueKeysWithValues: entries.map { ($0.title, $0.isEnabled) })
        #expect(byTitle["None"] == true)
        #expect(byTitle["A"] == true)
        #expect(byTitle["B"] == false)
        #expect(byTitle["C"] == false)
        #expect(byTitle["Moving"] == nil)
        #expect(byTitle["Child"] == nil)
    }

    @Test("The separator sits above the first group offered when the first one is left out")
    func separatorFollowsTheFirstOfferedGroup() {
        let only = group("Only")
        let other = group("Other")
        let entries = GroupMenuEntries.forMoving(groupId: only.id, groups: [only, other], noneTitle: "None")
        #expect(entries.filter { $0.hasSeparatorAbove }.map(\.title) == ["Other"])
    }

    @Test("A parent picker disables anything already at the nesting limit")
    func parentPickerDisablesAtLimit() {
        let root = group("A")
        let child = group("B", parent: root)
        let grandchild = group("C", parent: child)
        let entries = GroupMenuEntries.forParent(
            groups: [root, child, grandchild],
            noneTitle: "None"
        )
        let byTitle = Dictionary(uniqueKeysWithValues: entries.map { ($0.title, $0.isEnabled) })
        #expect(byTitle["A"] == true)
        #expect(byTitle["B"] == true)
        #expect(byTitle["C"] == false)
    }

    @Test("A connection picker never disables a group")
    func connectionPickerEnablesEverything() {
        let root = group("A")
        let child = group("B", parent: root)
        let grandchild = group("C", parent: child)
        let entries = GroupMenuEntries.forConnection(
            groups: [root, child, grandchild],
            noneTitle: "None"
        )
        let disabled = entries.filter { !$0.isEnabled }
        #expect(disabled.isEmpty)
    }
}

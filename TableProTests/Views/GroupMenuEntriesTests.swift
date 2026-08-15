//
//  GroupMenuEntriesTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

@Suite("Group menu entries")
struct GroupMenuEntriesTests {
    private func group(
        _ name: String,
        parent: ConnectionGroup? = nil,
        color: ConnectionColor = .none
    ) -> ConnectionGroup {
        ConnectionGroup(name: name, color: color, parentId: parent?.id)
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

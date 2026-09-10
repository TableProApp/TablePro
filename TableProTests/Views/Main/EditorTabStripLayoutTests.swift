import Foundation
@testable import TablePro
import Testing

@Suite("Editor tab strip layout")
struct EditorTabStripLayoutTests {
    private static let ids = (0..<5).map { _ in UUID() }

    @Test("Tabs share the track equally once each share clears the minimum")
    func equalShare() {
        let width = EditorTabStripLayout.tabWidth(forTrack: 604, count: 4)
        #expect(width == 150)
    }

    @Test("A crowded track stops shrinking at the minimum, so the strip scrolls instead")
    func minimumWidthFloor() {
        let width = EditorTabStripLayout.tabWidth(forTrack: 404, count: 20)
        #expect(width == EditorTabStripLayout.minimumTabWidth)
    }

    @Test("An empty tab list does not divide by zero")
    func emptyList() {
        let width = EditorTabStripLayout.tabWidth(forTrack: 404, count: 0)
        #expect(width == 400)
    }

    @Test("No separator leads the first tab")
    func firstTabHasNoSeparator() {
        #expect(
            EditorTabStripLayout.showsSeparator(
                before: 0,
                tabIds: Self.ids,
                selectedId: Self.ids[4],
                hoveredId: nil
            ) == false
        )
    }

    @Test("Two plain untouched neighbours get a separator")
    func plainNeighboursSeparate() {
        #expect(
            EditorTabStripLayout.showsSeparator(
                before: 2,
                tabIds: Self.ids,
                selectedId: Self.ids[4],
                hoveredId: nil
            )
        )
    }

    @Test("A separator is suppressed on both sides of the selected tab")
    func selectionSuppressesBothSides() {
        #expect(
            EditorTabStripLayout.showsSeparator(
                before: 2,
                tabIds: Self.ids,
                selectedId: Self.ids[2],
                hoveredId: nil
            ) == false
        )
        #expect(
            EditorTabStripLayout.showsSeparator(
                before: 3,
                tabIds: Self.ids,
                selectedId: Self.ids[2],
                hoveredId: nil
            ) == false
        )
    }

    @Test("A separator is suppressed on both sides of the hovered tab")
    func hoverSuppressesBothSides() {
        #expect(
            EditorTabStripLayout.showsSeparator(
                before: 2,
                tabIds: Self.ids,
                selectedId: Self.ids[4],
                hoveredId: Self.ids[2]
            ) == false
        )
        #expect(
            EditorTabStripLayout.showsSeparator(
                before: 3,
                tabIds: Self.ids,
                selectedId: Self.ids[4],
                hoveredId: Self.ids[2]
            ) == false
        )
    }

    /// One of two tabs is always the selected one, so the rule alone removes the separator.
    @Test("Two tabs never show a separator")
    func twoTabsNeverSeparate() {
        let pair = Array(Self.ids.prefix(2))
        #expect(
            EditorTabStripLayout.showsSeparator(
                before: 1,
                tabIds: pair,
                selectedId: pair[0],
                hoveredId: nil
            ) == false
        )
        #expect(
            EditorTabStripLayout.showsSeparator(
                before: 1,
                tabIds: pair,
                selectedId: pair[1],
                hoveredId: nil
            ) == false
        )
    }

    @Test("A reorder in progress clears every separator")
    func reorderSuppresses() {
        #expect(
            EditorTabStripLayout.showsSeparator(
                before: 2,
                tabIds: Self.ids,
                selectedId: Self.ids[4],
                hoveredId: nil,
                isReordering: true
            ) == false
        )
    }

    @Test("An index outside the list is not a separator")
    func outOfBoundsIsSafe() {
        #expect(
            EditorTabStripLayout.showsSeparator(
                before: 99,
                tabIds: Self.ids,
                selectedId: nil,
                hoveredId: nil
            ) == false
        )
    }
}

//
//  EditorTabReorderTests.swift
//  TableProTests
//
//  Issue #2438. The reorder these replace committed into QueryTabManager as the pointer crossed
//  each neighbour, which saved the tab list to disk on every crossing, so a drag the user gave up
//  on was already permanent. The order now lives here until the pointer comes up, which is what
//  makes a cancel possible at all, and the swap happens on a neighbour's midpoint rather than on
//  contact, which is what stops a tab flipping back and forth on a boundary.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Editor tab reorder")
struct EditorTabReorderTests {
    private static let ids = (0 ..< 5).map { _ in UUID() }

    private func makeReorder(dragging index: Int) -> EditorTabReorder {
        EditorTabReorder(draggedId: Self.ids[index], order: Self.ids)
    }

    @Test("A new reorder starts where the strip already was")
    func startsUnmoved() {
        let reorder = makeReorder(dragging: 0)

        #expect(reorder.order == Self.ids)
        #expect(reorder.originalOrder == Self.ids)
        #expect(reorder.movedFromOriginal == false)
        #expect(reorder.destinationIndex == 0)
    }

    @Test("Moving the dragged tab rewrites only the live order")
    func moveLeavesTheOriginalAlone() {
        var reorder = makeReorder(dragging: 0)

        reorder.move(to: 2)

        #expect(reorder.order == [Self.ids[1], Self.ids[2], Self.ids[0], Self.ids[3], Self.ids[4]])
        #expect(reorder.originalOrder == Self.ids)
        #expect(reorder.movedFromOriginal)
        #expect(reorder.destinationIndex == 2)
    }

    @Test("A destination past either end clamps instead of dropping the tab")
    func clampsAtBothEnds() {
        var forward = makeReorder(dragging: 0)
        forward.move(to: 99)
        #expect(forward.destinationIndex == 4)

        var backward = makeReorder(dragging: 4)
        backward.move(to: -3)
        #expect(backward.destinationIndex == 0)
    }

    @Test("Moving a tab back where it started leaves nothing to commit")
    func returningHomeIsNotAMove() {
        var reorder = makeReorder(dragging: 1)

        reorder.move(to: 3)
        reorder.move(to: 1)

        #expect(reorder.order == Self.ids)
        #expect(reorder.movedFromOriginal == false)
    }

    @Test("A tab closed mid-drag leaves the order rather than being committed back into it")
    func dropsAClosedTab() {
        var reorder = makeReorder(dragging: 0)
        let live = [Self.ids[0], Self.ids[1], Self.ids[3], Self.ids[4]]

        let kept = reorder.removingClosedTabs(keeping: live)

        #expect(kept)
        #expect(reorder.order == live)
    }

    @Test("Closing the tab being dragged ends the drag")
    func closingTheDraggedTabEndsIt() {
        var reorder = makeReorder(dragging: 2)
        let live = Self.ids.filter { $0 != Self.ids[2] }

        let kept = reorder.removingClosedTabs(keeping: live)

        #expect(kept == false)
    }
}

@Suite("Editor tab reorder resolver")
struct EditorTabReorderResolverTests {
    private let tabWidth: CGFloat = 100

    @Test("A pointer inside a tab resolves to that tab's index")
    func placesThePointer() {
        #expect(EditorTabReorderResolver.destination(forLocation: 0, tabWidth: tabWidth, count: 5) == 0)
        #expect(EditorTabReorderResolver.destination(forLocation: 99, tabWidth: tabWidth, count: 5) == 0)
        #expect(EditorTabReorderResolver.destination(forLocation: 100, tabWidth: tabWidth, count: 5) == 1)
        #expect(EditorTabReorderResolver.destination(forLocation: 250, tabWidth: tabWidth, count: 5) == 2)
    }

    @Test("A pointer past either end of the track clamps to the first or last tab")
    func clampsOutsideTheTrack() {
        #expect(EditorTabReorderResolver.destination(forLocation: -500, tabWidth: tabWidth, count: 5) == 0)
        #expect(EditorTabReorderResolver.destination(forLocation: 5_000, tabWidth: tabWidth, count: 5) == 4)
    }

    @Test("A track with no tabs, or tabs with no width, resolves to the first slot")
    func degenerateInputs() {
        #expect(EditorTabReorderResolver.destination(forLocation: 250, tabWidth: tabWidth, count: 0) == 0)
        #expect(EditorTabReorderResolver.destination(forLocation: 250, tabWidth: 0, count: 5) == 0)
    }

    /// The whole reason the swap is on the midpoint. Reordering the moment two tabs touch puts the
    /// displaced neighbour under the pointer, which satisfies the swap back, and the pair flip
    /// against each other for as long as the pointer sits near the boundary.
    @Test("A tab does not move until the pointer passes the middle of the tab it is moving into")
    func swapsOnTheMidpointNotOnContact() {
        let onContact = EditorTabReorderResolver.settledDestination(
            forLocation: 101,
            tabWidth: tabWidth,
            currentIndex: 0,
            count: 5
        )
        #expect(onContact == nil)

        let pastCentre = EditorTabReorderResolver.settledDestination(
            forLocation: 151,
            tabWidth: tabWidth,
            currentIndex: 0,
            count: 5
        )
        #expect(pastCentre == 1)
    }

    @Test("Moving left needs the pointer past the midpoint too")
    func swapsLeftOnTheMidpoint() {
        let onContact = EditorTabReorderResolver.settledDestination(
            forLocation: 299,
            tabWidth: tabWidth,
            currentIndex: 3,
            count: 5
        )
        #expect(onContact == nil)

        let pastCentre = EditorTabReorderResolver.settledDestination(
            forLocation: 249,
            tabWidth: tabWidth,
            currentIndex: 3,
            count: 5
        )
        #expect(pastCentre == 2)
    }

    /// macOS coalesces a fast drag, so one event can arrive several tabs along. Answering only for
    /// the tab under the pointer returned nothing here, and a quick drag committed a shorter move
    /// than the user made, or none at all.
    @Test("A drag that jumps past a neighbour still settles on the midpoint it crossed")
    func settlesOnACrossedMidpointAfterAJump() {
        let jumpedPastOne = EditorTabReorderResolver.settledDestination(
            forLocation: 220,
            tabWidth: tabWidth,
            currentIndex: 0,
            count: 5
        )
        #expect(jumpedPastOne == 1)

        let jumpedPastThree = EditorTabReorderResolver.settledDestination(
            forLocation: 420,
            tabWidth: tabWidth,
            currentIndex: 0,
            count: 5
        )
        #expect(jumpedPastThree == 3)
    }

    @Test("A leftward jump settles on the furthest midpoint it crossed")
    func settlesOnACrossedMidpointJumpingLeft() {
        let destination = EditorTabReorderResolver.settledDestination(
            forLocation: 180,
            tabWidth: tabWidth,
            currentIndex: 4,
            count: 5
        )
        #expect(destination == 2)
    }

    @Test("A pointer still over the dragged tab's own slot settles nowhere")
    func staysPut() {
        let destination = EditorTabReorderResolver.settledDestination(
            forLocation: 50,
            tabWidth: tabWidth,
            currentIndex: 0,
            count: 5
        )
        #expect(destination == nil)
    }

    @Test("A strip of one tab has nowhere to settle")
    func singleTabStrip() {
        let destination = EditorTabReorderResolver.settledDestination(
            forLocation: 400,
            tabWidth: tabWidth,
            currentIndex: 0,
            count: 1
        )
        #expect(destination == nil)
    }

    /// The track scrolls once the tabs stop fitting, which is why the strip names its coordinate
    /// space on the scroll view's content. A location well past the viewport is an ordinary
    /// position in that space, not an overshoot to clamp.
    @Test("A location beyond one screenful still resolves inside an overflowing strip")
    func resolvesPastTheViewport() {
        let destination = EditorTabReorderResolver.destination(
            forLocation: 1_450,
            tabWidth: EditorTabStripLayout.minimumTabWidth,
            count: 20
        )
        #expect(destination == 12)
    }
}

/// The boundary the commonest drag of all lands on.
@Suite("Editor tab reorder crossing tolerance")
struct EditorTabReorderCrossingToleranceTests {
    /// Releasing on a neighbour's exact centre is what a one-place drag does, and the location
    /// arrives from a geometry conversion, so it is a hair under the midpoint as often as it is on
    /// it. Comparing for equality made the move a coin flip; measured on the shipping strip, two
    /// of thirteen plain drags did nothing.
    @Test("A release a hair short of the midpoint still crosses it")
    func aHairShortOfTheMidpointCrosses() {
        let width: CGFloat = 244
        let midpoint = 2.5 * width

        #expect(
            EditorTabReorderResolver.settledDestination(
                forLocation: midpoint - 0.0001,
                tabWidth: width,
                currentIndex: 3,
                count: 6
            ) == 2
        )
    }

    @Test("A release a hair past the midpoint crosses it going the other way")
    func aHairPastTheMidpointCrosses() {
        let width: CGFloat = 244
        let midpoint = 3.5 * width

        #expect(
            EditorTabReorderResolver.settledDestination(
                forLocation: midpoint + 0.0001,
                tabWidth: width,
                currentIndex: 2,
                count: 6
            ) == 3
        )
    }

    /// The tolerance is half a point, which is below anything a hand or an eye can aim at. A tab
    /// still has to be genuinely crossed for the order to change.
    @Test("A release well short of the midpoint does not cross it")
    func wellShortOfTheMidpointDoesNotCross() {
        let width: CGFloat = 244

        #expect(
            EditorTabReorderResolver.settledDestination(
                forLocation: 2.5 * width + 4,
                tabWidth: width,
                currentIndex: 3,
                count: 6
            ) == nil
        )
    }
}

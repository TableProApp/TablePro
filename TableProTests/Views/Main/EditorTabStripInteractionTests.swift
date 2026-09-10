//
//  EditorTabStripInteractionTests.swift
//  TableProTests
//

import CoreGraphics
import Foundation
import Testing

@testable import TablePro

@MainActor
@Suite("Editor tab strip interaction")
struct EditorTabStripInteractionTests {
    private static let trackWidth: CGFloat = 604

    /// Records what the strip asked the app to do, so a reorder can be checked for reaching the
    /// tab manager exactly once and only on release.
    private final class Recorder {
        var moves: [(UUID, Int)] = []
        var activated: [UUID] = []
        var closed: [UUID] = []
    }

    private func makeInteraction(
        tabCount: Int,
        overflow: EditorTabStripOverflow = .scroll,
        recorder: Recorder = Recorder()
    ) -> (EditorTabStripInteraction, [UUID], Recorder) {
        let ids = (0 ..< tabCount).map { _ in UUID() }
        let interaction = EditorTabStripInteraction()
        interaction.overflow = overflow
        interaction.commands = EditorTabCommands(
            activate: { recorder.activated.append($0) },
            keepOpen: { _ in },
            canKeepOpen: { _ in false },
            close: { recorder.closed.append($0) },
            closeOthers: { _ in },
            closeAll: {},
            moveTab: { recorder.moves.append(($0, $1)) },
            canMove: { _, _ in true },
            moveBy: { _, _ in },
            tearOff: { _ in },
            canTearOff: { _ in false },
            tooltip: { _ in "" }
        )
        interaction.dropClosedTabs(keeping: ids)
        interaction.updateRun(trackWidth: Self.trackWidth, count: tabCount)
        return (interaction, ids, recorder)
    }

    @Test("A reorder draws from its own order and leaves the manager alone until release")
    func reorderIsNotCommittedUntilRelease() {
        let (interaction, ids, recorder) = makeInteraction(tabCount: 4)

        interaction.beginReorder(of: ids[0])
        interaction.updateReorder(toLinearLocation: interaction.run.tabWidth * 2.5)

        #expect(interaction.displayedIds != ids)
        #expect(recorder.moves.isEmpty)

        interaction.commitReorder()

        #expect(recorder.moves.count == 1)
        #expect(recorder.moves.first?.0 == ids[0])
        #expect(recorder.moves.first?.1 == 2)
        #expect(interaction.reorder == nil)
    }

    /// Escape drops the value the drag was building, and the manager was never written, so there
    /// is nothing to undo.
    @Test("A cancelled reorder writes nothing and puts the order back")
    func cancelledReorderWritesNothing() {
        let (interaction, ids, recorder) = makeInteraction(tabCount: 4)

        interaction.beginReorder(of: ids[0])
        interaction.updateReorder(toLinearLocation: interaction.run.tabWidth * 2.5)
        interaction.clearReorder()

        #expect(recorder.moves.isEmpty)
        #expect(interaction.displayedIds == ids)
    }

    @Test("A reorder that ends where it started writes nothing")
    func unmovedReorderWritesNothing() {
        let (interaction, ids, recorder) = makeInteraction(tabCount: 4)

        interaction.beginReorder(of: ids[1])
        interaction.commitReorder()

        #expect(recorder.moves.isEmpty)
    }

    /// The pointer and the keyboard are independent streams, so `Cmd+W` can close the tab that is
    /// mid-drag. A stale id must not reach the commit and put back a tab that is gone.
    @Test("Closing the dragged tab ends the drag")
    func closingTheDraggedTabEndsTheDrag() {
        let (interaction, ids, recorder) = makeInteraction(tabCount: 4)

        interaction.beginReorder(of: ids[0])
        interaction.dropClosedTabs(keeping: Array(ids.dropFirst()))

        #expect(interaction.reorder == nil)
        interaction.commitReorder()
        #expect(recorder.moves.isEmpty)
    }

    @Test("Closing another tab keeps the drag alive without it")
    func closingAnotherTabKeepsTheDrag() {
        let (interaction, ids, _) = makeInteraction(tabCount: 4)

        interaction.beginReorder(of: ids[0])
        interaction.dropClosedTabs(keeping: [ids[0], ids[1], ids[3]])

        #expect(interaction.reorder != nil)
        #expect(interaction.displayedIds.count == 3)
    }

    @Test("The track scrolls only as far as the content runs")
    func scrollingClampsToTheContent() {
        let (interaction, _, _) = makeInteraction(tabCount: 12)
        let maximum = interaction.run.contentSize.width - interaction.viewportWidth

        interaction.scroll(by: 10_000)
        #expect(interaction.contentOffset == maximum)

        interaction.scroll(by: -10_000)
        #expect(interaction.contentOffset == 0)
    }

    /// A wrapped run never overflows, so there is nothing to scroll and the wheel is inert.
    @Test("A wrapped run does not scroll")
    func wrappedRunDoesNotScroll() {
        let (interaction, _, _) = makeInteraction(tabCount: 12, overflow: .rows)

        interaction.scroll(by: 500)

        #expect(interaction.contentOffset == 0)
    }

    @Test("Revealing a tab scrolls it fully into the viewport from either side")
    func revealScrollsFromEitherSide() {
        let (interaction, ids, _) = makeInteraction(tabCount: 12)

        interaction.revealTab(id: ids[11])
        let placement = interaction.run.placement(at: 11)
        #expect(interaction.contentOffset == (placement?.frame.maxX ?? 0) - interaction.viewportWidth)

        interaction.revealTab(id: ids[0])
        #expect(interaction.contentOffset == 0)
    }

    @Test("Switching to rows drops the scroll offset the run no longer has")
    func switchingToRowsResetsTheOffset() {
        let (interaction, _, _) = makeInteraction(tabCount: 12)
        interaction.scroll(by: 400)
        #expect(interaction.contentOffset > 0)

        interaction.overflow = .rows

        #expect(interaction.contentOffset == 0)
        #expect(interaction.run.rowCount > 1)
    }
}

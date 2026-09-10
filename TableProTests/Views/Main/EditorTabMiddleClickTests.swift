//
//  EditorTabMiddleClickTests.swift
//  TableProTests
//

import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import TablePro

/// Middle-clicking a tab closes it, resolved against the same run layout the pointer already
/// hit-tests every other gesture with.
///
/// The gesture is driven through the view's own view-point entry points rather than through
/// synthesized events, because `NSEvent.mouseEvent(with:…)` cannot carry a button number:
/// measured, it reports 0 for `.otherMouseDown` and `.otherMouseUp` whatever else it is given, and
/// the only factory that reports 2 is `NSEvent(cgEvent:)`, whose location is a screen point. The
/// button half of the contract is covered on its own below.
@MainActor
@Suite("Editor tab middle click")
struct EditorTabMiddleClickTests {
    /// Chosen so the track measures the 604pt the strip's other tests use: the view gives up
    /// `stripInset` at the leading edge and the new-tab button plus its spacing at the trailing.
    private static let viewWidth: CGFloat = 652
    private static let tabCount = 3

    private final class Recorder {
        var closed: [UUID] = []
    }

    private func makeView(
        tabCount: Int = Self.tabCount,
        recorder: Recorder = Recorder()
    ) -> (EditorTabInteractionView, [UUID], Recorder) {
        let ids = (0 ..< tabCount).map { _ in UUID() }
        let interaction = EditorTabStripInteraction()
        interaction.commands = EditorTabCommands(
            activate: { _ in },
            keepOpen: { _ in },
            canKeepOpen: { _ in false },
            close: { recorder.closed.append($0) },
            closeOthers: { _ in },
            closeAll: {},
            moveTab: { _, _ in },
            canMove: { _, _ in true },
            moveBy: { _, _ in },
            tearOff: { _ in },
            canTearOff: { _ in false },
            tooltip: { _ in "" }
        )
        interaction.dropClosedTabs(keeping: ids)

        let view = EditorTabInteractionView(interaction: interaction)
        view.frame = CGRect(x: 0, y: 0, width: Self.viewWidth, height: EditorTabStripLayout.bandHeight)
        view.rebuildRun()
        return (view, ids, recorder)
    }

    /// The view point that lands on a given point of the run's content space, which is where the
    /// placements live. The two differ by the track's insets and by however far the run has
    /// scrolled, so a test that hardcodes the insets alone is only right at offset zero.
    private func viewPoint(ofContent point: CGPoint, in view: EditorTabInteractionView) -> CGPoint {
        CGPoint(
            x: point.x - view.interaction.contentOffset
                + EditorTabStripLayout.stripInset + EditorTabStripLayout.trackPadding,
            y: point.y + EditorTabStripLayout.trackPadding
        )
    }

    /// The centre of a tab, in the view's own flipped coordinates, built from the run the view just
    /// measured so the test and the code agree by construction rather than by arithmetic.
    private func centre(ofTabAt index: Int, in view: EditorTabInteractionView) throws -> CGPoint {
        let placement = try #require(view.interaction.run.placement(at: index))
        return viewPoint(ofContent: CGPoint(x: placement.frame.midX, y: placement.frame.midY), in: view)
    }

    @Test("A middle-click on a tab closes it")
    func middleClickClosesTheTab() throws {
        let (view, ids, recorder) = makeView()
        let point = try centre(ofTabAt: 1, in: view)

        view.beginMiddleClick(atViewPoint: point)
        view.endMiddleClick(atViewPoint: point)

        #expect(recorder.closed == [ids[1]])
    }

    /// The tab's own close button is drawn inside the tab, so a middle-click over it is still a
    /// middle-click on that tab and must not take the left button's path.
    @Test("A middle-click over the close button closes the same tab")
    func middleClickOverTheCloseButtonClosesTheTab() throws {
        let (view, ids, recorder) = makeView()
        let placement = try #require(view.interaction.run.placement(at: 2))
        let button = EditorTabRunLayoutBuilder.closeButtonRect(in: placement.frame)
        let point = CGPoint(
            x: button.midX + EditorTabStripLayout.stripInset + EditorTabStripLayout.trackPadding,
            y: button.midY + EditorTabStripLayout.trackPadding
        )

        view.beginMiddleClick(atViewPoint: point)
        view.endMiddleClick(atViewPoint: point)

        #expect(recorder.closed == [ids[2]])
    }

    /// The same contract the close button keeps: the release has to land where the press did, so a
    /// user who changes their mind can slide off and let go.
    @Test("Releasing on another tab closes nothing")
    func releasingOnAnotherTabClosesNothing() throws {
        let (view, _, recorder) = makeView()

        view.beginMiddleClick(atViewPoint: try centre(ofTabAt: 0, in: view))
        view.endMiddleClick(atViewPoint: try centre(ofTabAt: 2, in: view))

        #expect(recorder.closed.isEmpty)
    }

    @Test("Releasing off the strip closes nothing")
    func releasingOffTheStripClosesNothing() throws {
        let (view, _, recorder) = makeView()

        view.beginMiddleClick(atViewPoint: try centre(ofTabAt: 0, in: view))
        view.endMiddleClick(atViewPoint: CGPoint(x: Self.viewWidth - 4, y: 200))

        #expect(recorder.closed.isEmpty)
    }

    @Test("A press that missed every tab closes nothing")
    func pressOffATabClosesNothing() throws {
        let (view, _, recorder) = makeView()

        view.beginMiddleClick(atViewPoint: CGPoint(x: 2, y: 2))
        view.endMiddleClick(atViewPoint: try centre(ofTabAt: 1, in: view))

        #expect(recorder.closed.isEmpty)
    }

    /// The press is spent on release. Without that the strip would keep closing the same tab every
    /// time the button came up, which is what a mouse with a sticky wheel button would produce.
    @Test("A second release without a second press closes nothing")
    func secondReleaseClosesNothing() throws {
        let (view, ids, recorder) = makeView()
        let point = try centre(ofTabAt: 1, in: view)

        view.beginMiddleClick(atViewPoint: point)
        view.endMiddleClick(atViewPoint: point)
        view.endMiddleClick(atViewPoint: point)

        #expect(recorder.closed == [ids[1]])
    }

    /// A tab that went while the button was held leaves a different id in its slot, so the gesture
    /// finds nothing rather than closing whichever tab slid under the pointer.
    @Test("A tab closed under the pointer takes nothing with it")
    func tabClosedUnderThePointerTakesNothingWithIt() throws {
        let (view, ids, recorder) = makeView()
        let point = try centre(ofTabAt: 2, in: view)

        view.beginMiddleClick(atViewPoint: point)
        view.interaction.dropClosedTabs(keeping: [ids[0], ids[1]])
        view.rebuildRun()
        view.endMiddleClick(atViewPoint: point)

        #expect(recorder.closed.isEmpty)
    }

    /// The run scrolls under a fixed viewport, so a point outside the viewport still translates
    /// into content coordinates, and those land on whichever tab the offset happens to have put
    /// there. The track's own two points of padding are the nearest such point: pressing them on a
    /// scrolled strip resolved to a tab clipped off the leading edge and closed it.
    @Test("A press in the track padding of a scrolled strip closes nothing")
    func pressInTheTrackPaddingClosesNothing() throws {
        let (view, _, recorder) = makeView(tabCount: 12)
        view.interaction.scroll(by: 10_000)
        #expect(view.interaction.contentOffset > 0)
        let padding = CGPoint(x: EditorTabStripLayout.stripInset + 1, y: EditorTabStripLayout.trackPadding + 12)

        view.beginMiddleClick(atViewPoint: padding)
        view.endMiddleClick(atViewPoint: padding)

        #expect(recorder.closed.isEmpty)
    }

    /// AppKit hands the release to whichever view took the press however far the pointer has
    /// travelled, so the release arrives here with a location this view does not own. A tab
    /// straddling the leading edge is the case where the press and the release resolve to the same
    /// tab across that boundary, which is the one a same-tab check alone cannot catch.
    @Test("A release in the track padding of a scrolled strip closes nothing")
    func releaseInTheTrackPaddingClosesNothing() throws {
        let (view, _, recorder) = makeView(tabCount: 12)
        view.interaction.scroll(by: 150)
        let press = try centre(ofTabAt: 1, in: view)
        let padding = CGPoint(x: EditorTabStripLayout.stripInset + 1, y: press.y)

        view.beginMiddleClick(atViewPoint: press)
        view.endMiddleClick(atViewPoint: padding)

        #expect(recorder.closed.isEmpty)
    }

    /// The override reads the button before anything else, so the side buttons of a five-button
    /// mouse pass straight through to whoever else wants them.
    @Test("A release from another button closes nothing")
    func releaseFromAnotherButtonClosesNothing() throws {
        let (view, _, recorder) = makeView()
        let point = try centre(ofTabAt: 1, in: view)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .otherMouseUp,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0
            )
        )

        view.beginMiddleClick(atViewPoint: point)
        view.otherMouseUp(with: event)

        #expect(event.isMiddleButton == false)
        #expect(recorder.closed.isEmpty)
    }
}

/// `buttonNumber` is the only thing that tells the wheel button from the side buttons, and
/// `NSEvent(cgEvent:)` is the one factory that can carry it into a test.
@Suite("Middle mouse button")
struct NSEventMouseButtonTests {
    private func press(_ button: CGMouseButton) throws -> NSEvent {
        let cgEvent = try #require(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .otherMouseDown,
                mouseCursorPosition: .zero,
                mouseButton: button
            )
        )
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    @Test("The wheel button is the middle button")
    func centreButtonIsTheMiddleButton() throws {
        let event = try press(.center)
        #expect(event.isMiddleButton)
    }

    @Test("Neither of the two main buttons is the middle button")
    func mainButtonsAreNotTheMiddleButton() throws {
        let left = try press(.left)
        let right = try press(.right)
        #expect(left.isMiddleButton == false)
        #expect(right.isMiddleButton == false)
    }
}

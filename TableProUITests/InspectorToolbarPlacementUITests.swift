//
//  InspectorToolbarPlacementUITests.swift
//  TableProUITests
//
//  The inspector toggle used to ride the inspector's divider: a tracking separator splits the
//  toolbar into pane-aligned sections and leaves the items inside one leading-aligned, so opening
//  the pane walked the button inward by the width of the pane. Only geometry catches that, which
//  is why the identifier-order unit tests are not enough on their own.
//

import AppKit
import XCTest

final class InspectorToolbarPlacementUITests: UITestCase {
    /// The button is 44pt wide and the toolbar insets the trailing edge by a few points. The
    /// inspector is 270pt, so anything near that is the pane's width rather than padding.
    private let trailingEdgeTolerance: CGFloat = 80

    /// How far the grid has to narrow or widen before the pane counts as having changed state.
    /// The inspector's minimum thickness is 270pt.
    private let paneTravel: CGFloat = 100

    /// The window size is pinned because the measurement is a distance from the window's trailing
    /// edge: a restored frame narrow enough to overflow the toolbar would move the last item for
    /// reasons that have nothing to do with the inspector.
    private let pinnedWindowSize = CGSize(width: 1512, height: 861)

    private var pinnedEnvironment: [String: String] {
        ["TABLEPRO_SCREENSHOT_FRAME": "\(Int(pinnedWindowSize.width))x\(Int(pinnedWindowSize.height))"]
    }

    /// The only handle on the toggle is the label AppKit gives its own standard item, which is
    /// localized, so the app has to run in a known language. `AppleLanguages` is a defaults key
    /// rather than an environment variable, and this test used to pass it in the environment, where
    /// nothing reads it: the match worked only because both machines happened to be English.
    private let pinnedArguments = ["-AppleLanguages", "(en)"]

    /// The inspector remembers whether it was open, so the starting state is whatever the previous
    /// launch left. Both directions are asserted rather than assuming one.
    func testTheInspectorToggleHoldsTheTrailingEdgeThroughBothTransitions() throws {
        try skipUnlessTheScreenFitsThePinnedWindow()
        let app = try launchWithSampleDatabase(
            environment: pinnedEnvironment,
            arguments: pinnedArguments
        )
        let window = try mainWindow(of: app)
        let toggle = try inspectorToggle(in: window)

        let initialGap = window.frame.maxX - toggle.frame.maxX
        XCTAssertLessThan(
            initialGap,
            trailingEdgeTolerance,
            "The inspector toggle must start at the window's trailing edge"
        )

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "The sample database produced no data grid")

        for transition in 1 ... 2 {
            let widthBefore = grid.frame.width
            app.typeKey("i", modifierFlags: [.command, .option])

            XCTAssertTrue(
                waitForPredicate(timeout: 15) { abs(grid.frame.width - widthBefore) > self.paneTravel },
                "Transition \(transition): Command Option I did not move the inspector"
            )

            let gap = window.frame.maxX - toggle.frame.maxX
            XCTAssertLessThan(
                gap,
                trailingEdgeTolerance,
                "Transition \(transition): the toggle drifted in from the window's trailing edge"
            )
            XCTAssertEqual(
                gap,
                initialGap,
                accuracy: 1,
                "Transition \(transition): moving the inspector must not move its own toggle"
            )
        }
    }

    // MARK: - Helpers

    /// A window pinned wider than the screen is placed partly off it, and its toolbar collapses the
    /// trailing items into the overflow menu, so there is no toggle in the toolbar to measure at
    /// all. That is unmeasurable rather than wrong, and it is what the CI runner is: a 1024x768
    /// virtual machine, where this reported "No inspector toggle in the toolbar" on every run while
    /// passing on any real display.
    private func skipUnlessTheScreenFitsThePinnedWindow() throws {
        /// Width only, and against the screen's own frame rather than its visible one. The failure
        /// this guards is horizontal, and the menu bar and Dock take height, not toolbar room.
        let width = NSScreen.main?.frame.width ?? 0
        try XCTSkipUnless(
            width >= pinnedWindowSize.width,
            """
            Needs a screen at least \(Int(pinnedWindowSize.width))pt wide to hold the pinned window; \
            this one is \(Int(width))pt. Anything narrower overflows the toolbar's trailing items \
            into its menu, and the toggle is then not in the toolbar to measure.
            """
        )
    }

    private func mainWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 60), "The sample database produced no window")
        return window
    }

    /// AppKit builds this item itself and labels it "Inspector"; the app never vends it, so there
    /// is no accessibility identifier of ours to match on.
    private func inspectorToggle(in window: XCUIElement) throws -> XCUIElement {
        let toggle = window.toolbars.buttons["Inspector"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "No inspector toggle in the toolbar")
        return toggle
    }
}

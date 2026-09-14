//
//  NavigationSidebarLayoutTests.swift
//  TableProTests
//
//  An NSSplitView held these two panes and had to go: it sets its panes' frames itself, and each
//  write re-dirtied the constraints of the wrapper the window's sidebar item puts around this view.
//  AppKit gave up with "more Update Constraints in Window passes than there are views in the
//  window" and the process died before its first window was drawn. The layout is plain constraints
//  now, and this is what says so, because the UI test that covers the tree needs a runner and a
//  runner needs someone at the machine.
//

import AppKit
@testable import TablePro
import Testing

@MainActor
@Suite("Navigation sidebar layout")
struct NavigationSidebarLayoutTests {
    /// Hosted in a real window, not just given a frame. A view that is only assigned a frame and
    /// asked to lay out never gets the engine's window-level pass: measured, every pane came back
    /// at its intrinsic height, 35pt and 34pt, whatever size the view was told it had. A test built
    /// that way measures nothing the app does.
    private func laidOut(width: CGFloat, height: CGFloat) -> NavigationSidebarViewController {
        let controller = NavigationSidebarViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        /// The size is applied after the controller, not with it: assigning `contentViewController`
        /// resizes the window to the view's fitting size, which threw away the `contentRect` above
        /// and left every pane measuring the same whatever size the test asked for.
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    @Test("Both panes are on screen with a size")
    func bothPanesGetRoom() {
        let controller = laidOut(width: 280, height: 800)
        let tree = controller.connectionTree.view
        let browser = controller.objectBrowser.view
        #expect(tree.frame.height > 0)
        #expect(browser.frame.height > 0)
        #expect(tree.frame.width > 0)
        #expect(browser.frame.width > 0)
    }

    /// `NSView` is not flipped, so the origin is bottom left and the pane on top is the one with
    /// the higher `maxY`.
    @Test("The connections list sits above the object browser")
    func connectionsSitAbove() {
        let controller = laidOut(width: 280, height: 800)
        let tree = controller.connectionTree.view
        let browser = controller.objectBrowser.view
        #expect(tree.frame.maxY > browser.frame.maxY)
        #expect(tree.frame.minY >= browser.frame.maxY)
    }

    @Test("The list takes its slice and the browser takes the rest")
    func listTakesItsSlice() {
        let controller = laidOut(width: 280, height: 800)
        let tree = controller.connectionTree.view
        let browser = controller.objectBrowser.view
        #expect(abs(tree.frame.height - 200) < 1)
        #expect(browser.frame.height > tree.frame.height)
    }

    /// The height is a preference, not a requirement. A window too short for it shrinks the list
    /// rather than leaving the layout unsatisfiable, which is what an unbreakable constraint here
    /// would do on the first small window.
    @Test("A short sidebar shrinks the list instead of breaking")
    func shortSidebarShrinksTheList() {
        let controller = laidOut(width: 280, height: 300)
        let tree = controller.connectionTree.view
        let browser = controller.objectBrowser.view
        #expect(tree.frame.height <= 300 * 0.4 + 1)
        #expect(tree.frame.height > 0)
        #expect(browser.frame.height > 0)
    }

    /// The panes together are the sidebar, with the rule between them. Anything else means a
    /// constraint was broken, which AppKit does silently.
    @Test("The panes and their rule fill the sidebar exactly", arguments: [300.0, 600.0, 800.0, 1_200.0])
    func panesFillTheSidebar(height: CGFloat) {
        let controller = laidOut(width: 280, height: height)
        let total = controller.connectionTree.view.frame.height
            + 1
            + controller.objectBrowser.view.frame.height
        #expect(abs(total - controller.view.frame.height) < 1)
    }

    @Test("Neither pane overlaps the other")
    func panesDoNotOverlap() {
        for height in [300.0, 600.0, 1_200.0] {
            let controller = laidOut(width: 280, height: height)
            let tree = controller.connectionTree.view
            let browser = controller.objectBrowser.view
            #expect(!tree.frame.intersects(browser.frame))
        }
    }
}

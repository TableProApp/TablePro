import AppKit
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

/// The connections strip shares a split view with the object browser inside the sidebar, so the
/// line between them is a divider the user drags to read longer connection and database names.
@MainActor
struct NavigationSidebarRailWidthTests {
    @Test("A strip that is not shown reserves no width")
    func hiddenStripReservesNothing() {
        let host = SidebarHost()
        defer { host.tearDown() }

        #expect(host.sidebar.railAllowance == 0)

        host.sidebar.setRailVisible(true, animated: false)
        host.sidebar.setRailVisible(false, animated: false)

        #expect(host.sidebar.railAllowance == 0)
    }

    @Test("A strip shown for the first time opens at its minimum width")
    func firstShowOpensAtTheMinimum() throws {
        let host = SidebarHost()
        defer { host.tearDown() }

        host.sidebar.setRailVisible(true, animated: false)
        host.layout()

        let minimum = host.sidebar.railController.currentLayout.minimumWidth
        #expect(host.rail.frame.width == minimum)
        #expect(try host.sidebar.railAllowance == minimum + host.splitView().dividerThickness)
    }

    @Test("Dragging the divider widens the strip and reports the new width")
    func draggingWidensTheStrip() throws {
        let host = SidebarHost()
        defer { host.tearDown() }
        var widthChanges = 0
        host.sidebar.onRailWidthChange = { widthChanges += 1 }
        host.sidebar.setRailVisible(true, animated: false)
        host.layout()
        widthChanges = 0

        let splitView = try host.splitView()
        splitView.setPosition(170, ofDividerAt: 0)
        host.layout()

        #expect(host.rail.frame.width == 170)
        #expect(host.sidebar.railAllowance == 170 + splitView.dividerThickness)
        #expect(widthChanges > 0)
    }

    @Test("The strip stops at its maximum width")
    func stripStopsAtItsMaximum() throws {
        let host = SidebarHost()
        defer { host.tearDown() }
        host.sidebar.setRailVisible(true, animated: false)
        host.layout()

        try host.splitView().setPosition(1_000, ofDividerAt: 0)
        host.layout()

        #expect(host.rail.frame.width == WorkspaceRailMetrics.maximumWidth)
    }

    @Test("Dragging stops where the object browser reaches its own minimum")
    func objectBrowserKeepsItsMinimum() throws {
        let host = SidebarHost(width: 400)
        defer { host.tearDown() }
        host.sidebar.setRailVisible(true, animated: false)
        host.layout()

        let splitView = try host.splitView()
        splitView.setPosition(1_000, ofDividerAt: 0)
        host.layout()

        #expect(
            host.sidebar.objectBrowser.view.frame.width
                == NavigationSidebarViewController.objectBrowserMinimumThickness
        )
        #expect(
            host.rail.frame.width
                == 400 - splitView.dividerThickness - NavigationSidebarViewController.objectBrowserMinimumThickness
        )
    }

    /// The strip hides whenever the app-wide entry count drops to one, so a width that did not
    /// survive hiding would be lost every time the second connection closed.
    @Test("A hidden strip comes back at the width it was given")
    func hidingKeepsTheWidth() throws {
        let host = SidebarHost()
        defer { host.tearDown() }
        host.sidebar.setRailVisible(true, animated: false)
        host.layout()
        let splitView = try host.splitView()
        splitView.setPosition(170, ofDividerAt: 0)
        host.layout()

        host.sidebar.setRailVisible(false, animated: false)
        host.layout()
        host.sidebar.setRailVisible(true, animated: false)
        host.layout()

        #expect(host.rail.frame.width == 170)
        #expect(host.sidebar.railAllowance == 170 + splitView.dividerThickness)
    }

    @Test("A hidden strip gives the object browser the whole sidebar, divider included")
    func hiddenStripLeavesNoDivider() {
        let host = SidebarHost()
        defer { host.tearDown() }
        let browser = host.sidebar.objectBrowser.view
        host.sidebar.setRailVisible(true, animated: false)
        host.layout()
        #expect(host.frameInSidebar(browser).minX > 0)

        host.sidebar.setRailVisible(false, animated: false)
        host.layout()

        #expect(host.frameInSidebar(browser).minX == 0)
        #expect(host.frameInSidebar(browser).width == host.sidebar.view.bounds.width)
    }

    /// The `NSBox` this replaced started below the titlebar. A split view pinned to the top of the
    /// sidebar would run its divider up beside the window buttons.
    @Test("The divider starts below the titlebar")
    func dividerStartsBelowTheTitlebar() throws {
        let host = SidebarHost()
        defer { host.tearDown() }
        host.sidebar.setRailVisible(true, animated: false)
        host.layout()

        let titlebar = host.sidebar.view.safeAreaInsets.top
        try #require(titlebar > 0, "The window has to extend under its titlebar for this to test anything")
        let splitView = try host.splitView()
        #expect(host.frameInSidebar(splitView).maxY == host.sidebar.view.bounds.height - titlebar)
    }

    @MainActor
    struct SidebarHost {
        let sidebar: NavigationSidebarViewController
        let window: NSWindow

        var rail: NSView {
            sidebar.railController.view
        }

        init(width: CGFloat = 600) {
            sidebar = NavigationSidebarViewController()
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = sidebar
            window.setContentSize(NSSize(width: width, height: 400))
            window.orderFront(nil)
        }

        func layout() {
            window.layoutIfNeeded()
            sidebar.view.layoutSubtreeIfNeeded()
        }

        func splitView() throws -> NSSplitView {
            try #require(sidebar.view.firstDescendant(of: NSSplitView.self))
        }

        /// In the sidebar's own coordinates: each pane's view sits inside a wrapper AppKit owns.
        func frameInSidebar(_ pane: NSView) -> NSRect {
            pane.convert(pane.bounds, to: sidebar.view)
        }

        func tearDown() {
            window.orderOut(nil)
            window.contentViewController = nil
        }
    }
}

extension GlobalStateSuites {
    @MainActor
    struct NavigationSidebarRailLayoutTests {
        /// The sidebar icon size sets how much room a label needs, so it sets the strip's minimum.
        /// The width the user chose comes back once the minimum drops again.
        @Test(
            "A larger sidebar icon size widens a narrower strip, and a smaller one gives its width back",
            .appSettings { $0.general.sidebarRowSize = .medium }
        )
        func iconSizeSetsTheMinimum() {
            let host = NavigationSidebarRailWidthTests.SidebarHost()
            defer { host.tearDown() }
            host.sidebar.setRailVisible(true, animated: false)
            host.layout()
            #expect(host.rail.frame.width == WorkspaceRailMetrics.medium.minimumWidth)

            AppSettingsManager.shared.general.sidebarRowSize = .large
            host.sidebar.railController.refreshLayoutIfNeeded()
            host.sidebar.applyRailLayout()
            host.layout()
            #expect(host.rail.frame.width == WorkspaceRailMetrics.large.minimumWidth)

            AppSettingsManager.shared.general.sidebarRowSize = .medium
            host.sidebar.railController.refreshLayoutIfNeeded()
            host.sidebar.applyRailLayout()
            host.layout()
            #expect(host.rail.frame.width == WorkspaceRailMetrics.medium.minimumWidth)
        }

        @Test(
            "A strip first loaded at the small icon size opens at the small minimum",
            .appSettings { $0.general.sidebarRowSize = .small }
        )
        func smallIconSizeOpensNarrow() {
            let host = NavigationSidebarRailWidthTests.SidebarHost()
            defer { host.tearDown() }

            host.sidebar.setRailVisible(true, animated: false)
            host.layout()

            #expect(host.rail.frame.width == WorkspaceRailMetrics.small.minimumWidth)
        }

        /// The range used to be read off the width constraints while `animator()` was still moving
        /// them, so after the strip slid in the sidebar kept its old minimum and the object browser
        /// was squeezed below its own until the next drag. Raising it before the strip moved instead
        /// snapped the sidebar wide in one frame, so it lands once the strip is in.
        @Test(
            "An animated show widens the sidebar's range once the strip is in, not before",
            .appSettings {
                $0.general.showWorkspaceRail = true
                $0.general.sidebarRowSize = .medium
            }
        )
        func animatedShowWidensTheSidebarRange() async throws {
            let host = MainWindowHost()
            defer { host.tearDown() }
            let hidden = host.split.sidebarThicknessRange

            host.split.applyRailVisibility(workspaceCount: 2)
            try #require(host.split.isWorkspaceRailVisible)
            #expect(host.split.sidebarThicknessRange.min == hidden.min)
            #expect(host.split.sidebarThicknessRange.max == hidden.max)

            try await host.waitForRail()
            let allowance = WorkspaceRailMetrics.medium.minimumWidth + 1
            #expect(host.split.railAllowance == allowance)
            #expect(
                host.split.sidebarThicknessRange.min
                    == MainSplitViewController.resolveSidebarMinimumThickness(railAllowance: allowance)
            )
            #expect(
                host.split.sidebarThicknessRange.max
                    == MainSplitViewController.resolveSidebarMaximumThickness(railAllowance: allowance)
            )
            #expect(host.objectBrowserWidth >= NavigationSidebarViewController.objectBrowserMinimumThickness)
        }

        @Test(
            "Widening the strip widens the sidebar's range with it",
            .appSettings {
                $0.general.showWorkspaceRail = true
                $0.general.sidebarRowSize = .medium
            }
        )
        func wideningTheStripWidensTheSidebarRange() async throws {
            let host = MainWindowHost()
            defer { host.tearDown() }
            host.split.applyRailVisibility(workspaceCount: 2)
            try await host.waitForRail()

            let railSplit = try host.railSplitView()
            railSplit.setPosition(200, ofDividerAt: 0)
            host.window.layoutIfNeeded()

            let allowance = 200 + railSplit.dividerThickness
            #expect(host.split.railAllowance == allowance)
            #expect(
                host.split.sidebarThicknessRange.min
                    == MainSplitViewController.resolveSidebarMinimumThickness(railAllowance: allowance)
            )
        }

        /// The sidebar's own split controller sits between the sidebar's views and the window's in the
        /// responder chain. It holds neither a sidebar nor an inspector item, so the window's View
        /// commands must pass it by.
        @Test(
            "Pane commands sent from inside the sidebar reach the window's split, not the sidebar's",
            .appSettings {
                $0.general.showWorkspaceRail = true
                $0.general.sidebarRowSize = .medium
            }
        )
        func paneCommandsPassTheSidebarSplit() async throws {
            let host = MainWindowHost()
            defer { host.tearDown() }
            host.split.applyRailVisibility(workspaceCount: 2)
            try await host.waitForRail()
            let sidebar = try host.navigationSidebar()

            var actions = [#selector(NSSplitViewController.toggleSidebar(_:))]
            if #available(macOS 14.0, *) {
                actions.append(#selector(NSSplitViewController.toggleInspector(_:)))
            }
            for start in [sidebar.objectBrowser.view, sidebar.railController.view] {
                for action in actions {
                    let handler = firstResponder(answering: action, from: start)
                    #expect(
                        handler === host.split || handler === host.split.splitView,
                        "\(action) from \(type(of: start)) stopped at \(String(describing: handler))"
                    )
                }
            }
        }

        private func firstResponder(answering action: Selector, from start: NSResponder) -> NSResponder? {
            var responder: NSResponder? = start
            while let current = responder {
                if current.responds(to: action) { return current }
                responder = current.nextResponder
            }
            return nil
        }

        /// A smaller size used to leave the range 10pt high: it was read while the strip still had
        /// the larger size's width.
        @Test(
            "The sidebar's range follows the strip through a larger and a smaller sidebar icon size",
            .appSettings {
                $0.general.showWorkspaceRail = true
                $0.general.sidebarRowSize = .medium
            }
        )
        func sidebarRangeFollowsTheIconSize() async throws {
            let host = MainWindowHost()
            defer { host.tearDown() }
            host.split.applyRailVisibility(workspaceCount: 2)
            try await host.waitForRail()

            for (preference, layout) in [
                (SidebarRowSizePreference.large, WorkspaceRailMetrics.large),
                (.medium, WorkspaceRailMetrics.medium),
            ] {
                AppSettingsManager.shared.general.sidebarRowSize = preference
                try host.navigationSidebar().railController.refreshLayoutIfNeeded()
                host.window.layoutIfNeeded()

                #expect(
                    host.split.sidebarThicknessRange.min
                        == MainSplitViewController.resolveSidebarMinimumThickness(
                            railAllowance: layout.minimumWidth + 1
                        ),
                    "at \(preference)"
                )
            }
        }
    }
}

@MainActor
private struct MainWindowHost {
    let window: NSWindow
    let split: MainSplitViewController
    let workspace: ConnectionWorkspace

    init() {
        let connection = TestFixtures.makeConnection(name: "Rail width")
        workspace = ConnectionWorkspace(
            connectionId: connection.id,
            payload: nil,
            autoConnect: false,
            payloadConnection: connection,
            session: nil,
            sessionState: nil,
            trailingPaneState: nil,
            phase: .connecting
        )
        window = TabWindowController.makeEditorWindow()
        window.isReleasedWhenClosed = false
        split = MainSplitViewController(payload: nil, sessionState: nil, adopting: workspace)
        window.contentViewController = split
        window.orderFront(nil)
    }

    func navigationSidebar() throws -> NavigationSidebarViewController {
        try #require(split.sidebarSplitItem.viewController as? NavigationSidebarViewController)
    }

    func railSplitView() throws -> NSSplitView {
        try #require(split.sidebarSplitItem.viewController.view.firstDescendant(of: NSSplitView.self))
    }

    var objectBrowserWidth: CGFloat {
        (try? navigationSidebar().objectBrowser.view.frame.width) ?? 0
    }

    /// A shown strip slides in, and reserves its width only once it is in.
    func waitForRail() async throws {
        try await waitUntil { split.railAllowance > 0 }
        window.layoutIfNeeded()
    }

    func tearDown() {
        window.orderOut(nil)
        window.contentViewController = nil
        workspace.teardown()
    }
}

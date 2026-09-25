//
//  InspectorToolbarPlacementTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Inspector toolbar placement", .serialized)
@MainActor
struct InspectorToolbarPlacementTests {
    private static let pinnedWindowSize = CGSize(width: 1_512, height: 861)
    private static let trailingEdgeTolerance: CGFloat = 80
    private static let paneTravel: CGFloat = 100

    @Test("The inspector toggle holds the window's trailing edge as the inspector opens and closes")
    func toggleHoldsTheTrailingEdgeThroughBothTransitions() throws {
        let harness = try Harness(windowSize: Self.pinnedWindowSize)
        defer { harness.tearDown() }

        #expect(harness.window.frame.size == Self.pinnedWindowSize)
        let initialGap = try harness.toggleGapFromTrailingEdge()
        #expect(initialGap < Self.trailingEdgeTolerance, "The toggle starts \(initialGap)pt in from the trailing edge")

        for transition in 1 ... 2 {
            let detailWidthBefore = harness.detailWidth
            let refreshBefore = try harness.refreshMaxX()

            harness.setInspectorOpen(!harness.isInspectorOpen)

            #expect(
                abs(harness.detailWidth - detailWidthBefore) > Self.paneTravel,
                "Transition \(transition): the inspector did not move"
            )
            #expect(
                abs(try harness.refreshMaxX() - refreshBefore) > Self.paneTravel,
                "Transition \(transition): the toolbar did not lay out again for the new pane width"
            )
            let gap = try harness.toggleGapFromTrailingEdge()
            #expect(gap < Self.trailingEdgeTolerance, "Transition \(transition): the toggle is \(gap)pt in")
            #expect(abs(gap - initialGap) <= 1, "Transition \(transition): the toggle moved with the inspector")
        }
    }

    @MainActor
    private struct Harness {
        let controller: TabWindowController
        let split: MainSplitViewController
        let window: NSWindow
        private let workspace: ConnectionWorkspace
        private let connectionId: UUID

        init(windowSize: CGSize) throws {
            let connection = TestFixtures.makeConnection(name: "Inspector toggle", type: .mysql)
            connectionId = connection.id
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
            controller = TabWindowController(
                payload: EditorTabPayload(connectionId: connection.id),
                pinnedWindowSize: windowSize,
                adopting: workspace
            )
            window = try #require(controller.window)
            split = try #require(window.contentViewController as? MainSplitViewController)

            var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
            session.status = .connected
            DatabaseManager.shared.injectSession(session, for: connection.id)
            split.refreshFromActiveSessions()

            let toolbar = ContextValidatedToolbar(
                identifier: NSToolbar.Identifier("com.TablePro.tests.inspector.\(UUID().uuidString)")
            )
            let owner = MainWindowToolbar(managedToolbar: toolbar)
            toolbar.autosavesConfiguration = false
            split.toolbarOwner = owner
            split.pointToolbar(at: nil)
            split.sidebarSplitItem.isCollapsed = false
            setInspectorOpen(false)
        }

        var isInspectorOpen: Bool {
            split.isTrailingPaneOpen
        }

        var detailWidth: CGFloat {
            split.splitViewItems.first { $0.behavior == .default }?.viewController.view.frame.width ?? 0
        }

        func setInspectorOpen(_ isOpen: Bool) {
            split.inspectorSplitItem.isCollapsed = !isOpen
            window.layoutIfNeeded()
        }

        func toggleGapFromTrailingEdge() throws -> CGFloat {
            let toggle = try #require(control(sending: "toggleInspector:"), "No inspector toggle in the toolbar")
            return window.frame.width - toggle.convert(toggle.bounds, to: nil).maxX
        }

        func refreshMaxX() throws -> CGFloat {
            let refresh = try #require(control(sending: "performRefresh:"), "No Refresh item in the toolbar")
            return refresh.convert(refresh.bounds, to: nil).maxX
        }

        private func control(sending action: String) -> NSControl? {
            guard let frame = window.contentView?.superview else { return nil }
            return Self.firstControl(in: frame) { control in
                control.action.map(NSStringFromSelector) == action && !control.isHiddenOrHasHiddenAncestor
            }
        }

        private static func firstControl(in view: NSView, where matches: (NSControl) -> Bool) -> NSControl? {
            if let control = view as? NSControl, matches(control) { return control }
            for subview in view.subviews {
                if let found = firstControl(in: subview, where: matches) { return found }
            }
            return nil
        }

        func tearDown() {
            setInspectorOpen(false)
            split.invalidateToolbar()
            window.delegate = nil
            window.contentViewController = nil
            workspace.teardown()
            DatabaseManager.shared.removeSession(for: connectionId)
        }
    }
}

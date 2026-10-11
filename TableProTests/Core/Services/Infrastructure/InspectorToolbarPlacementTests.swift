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
        let fixture = try OffscreenConnectionWindow(
            size: Self.pinnedWindowSize,
            connectedTo: TestFixtures.makeConnection(name: "Inspector toggle", type: .mysql)
        )
        defer { fixture.tearDown() }

        #expect(fixture.window.frame.size == Self.pinnedWindowSize)
        let initialGap = try toggleGapFromTrailingEdge(in: fixture)
        #expect(initialGap < Self.trailingEdgeTolerance, "The toggle starts \(initialGap)pt in from the trailing edge")

        for transition in 1 ... 2 {
            let detailWidthBefore = detailWidth(in: fixture)
            let refreshBefore = try refreshMaxX(in: fixture)

            fixture.setInspectorOpen(!fixture.split.isTrailingPaneOpen)

            #expect(
                abs(detailWidth(in: fixture) - detailWidthBefore) > Self.paneTravel,
                "Transition \(transition): the inspector did not move"
            )
            #expect(
                abs(try refreshMaxX(in: fixture) - refreshBefore) > Self.paneTravel,
                "Transition \(transition): the toolbar did not lay out again for the new pane width"
            )
            let gap = try toggleGapFromTrailingEdge(in: fixture)
            #expect(gap < Self.trailingEdgeTolerance, "Transition \(transition): the toggle is \(gap)pt in")
            #expect(abs(gap - initialGap) <= 1, "Transition \(transition): the toggle moved with the inspector")
        }
    }

    private func detailWidth(in fixture: OffscreenConnectionWindow) -> CGFloat {
        fixture.split.splitViewItems.first { $0.behavior == .default }?.viewController.view.frame.width ?? 0
    }

    private func toggleGapFromTrailingEdge(in fixture: OffscreenConnectionWindow) throws -> CGFloat {
        let toggle = try #require(
            control(sending: "toggleInspector:", in: fixture),
            "No inspector toggle in the toolbar"
        )
        return fixture.window.frame.width - toggle.convert(toggle.bounds, to: nil).maxX
    }

    private func refreshMaxX(in fixture: OffscreenConnectionWindow) throws -> CGFloat {
        let refresh = try #require(control(sending: "performRefresh:", in: fixture), "No Refresh item in the toolbar")
        return refresh.convert(refresh.bounds, to: nil).maxX
    }

    private func control(sending action: String, in fixture: OffscreenConnectionWindow) -> NSControl? {
        guard let frame = fixture.themeFrame else { return nil }
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
}

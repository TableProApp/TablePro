//
//  TrailingPaneHeaderModelTests.swift
//  TableProTests
//
//  The pane's three surfaces drew three different headers: a title over a subtitle beside a picker,
//  a headline beside two buttons, and an icon-only picker as the whole top edge. They draw one now,
//  from one value, and these pin what that value says for each surface in each mode.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct TrailingPaneHeaderModelTests {
    // MARK: - Segments and title

    @Test("Browsing with AI on offers a picker between the inspector and the assistant")
    func browsingOffersBothSurfaces() {
        for surface in [TrailingPaneSurface.inspector, .assistant] {
            let model = TrailingPaneHeaderModel(surface: surface, contentMode: .browse, isAIEnabled: true)
            #expect(model.segments == [.inspector, .assistant], "\(surface)")
            #expect(model.showsPicker, "\(surface)")
        }
    }

    /// A single segment is a control with nothing to choose, which is what the AI setting being off
    /// leaves, so the header names the surface instead.
    @Test("With AI off the header names the inspector rather than drawing a one-segment picker")
    func aiOffDrawsATitle() {
        let model = TrailingPaneHeaderModel(surface: .inspector, contentMode: .browse, isAIEnabled: false)
        #expect(model.segments == [.inspector])
        #expect(!model.showsPicker)
        #expect(model.title == TrailingPaneSurface.inspector.localizedTitle)
    }

    @Test("Agent mode names the result, with nothing to choose")
    func agentModeDrawsTheResultTitle() {
        let model = TrailingPaneHeaderModel(surface: .agentResult, contentMode: .agent, isAIEnabled: true)
        #expect(model.segments.isEmpty)
        #expect(!model.showsPicker)
        #expect(model.title == String(localized: "Result"))
    }

    /// The picker draws the surface it sits over as selected, so a surface outside the segments would
    /// be a picker with nothing selected.
    @Test("A surface the picker does not offer never draws the picker")
    func unofferedSurfaceDrawsATitle() {
        let model = TrailingPaneHeaderModel(surface: .agentResult, contentMode: .browse, isAIEnabled: true)
        #expect(!model.showsPicker)
    }

    // MARK: - The menu

    @Test("The inspector's menu offers its renderings, and the JSON commands only over JSON")
    func inspectorMenu() {
        let fields = TrailingPaneHeaderModel(
            surface: .inspector,
            contentMode: .browse,
            isAIEnabled: true,
            inspectorRendering: .fields
        )
        #expect(fields.menuSections == [.inspectorRendering])

        let json = TrailingPaneHeaderModel(
            surface: .inspector,
            contentMode: .browse,
            isAIEnabled: true,
            inspectorRendering: .json
        )
        #expect(json.menuSections == [.inspectorRendering, .jsonReading])
    }

    /// A schema grid's column definition has no JSON form, and a pane with no row draws table info or
    /// nothing. A dimmed choice there still checked the stored rendering, which after JSON was picked
    /// elsewhere on the connection read JSON over a pane drawing fields.
    @Test("A selection with one rendering offers no choice between two")
    func singleRenderingOffersNoChoice() {
        let model = TrailingPaneHeaderModel(
            surface: .inspector,
            contentMode: .browse,
            isAIEnabled: true,
            inspectorRendering: nil
        )
        #expect(!model.menuSections.contains(.inspectorRendering))
        #expect(!model.menuSections.contains(.jsonReading))
    }

    /// Clear Recents is its own section because it deletes, and its confirmation stays with it.
    @Test("The assistant's menu offers its conversations, with Clear Recents apart")
    func assistantMenu() {
        let model = TrailingPaneHeaderModel(surface: .assistant, contentMode: .browse, isAIEnabled: true)
        #expect(model.menuSections == [.conversations, .clearRecents])
    }

    @Test("The result's menu offers its views")
    func resultMenu() {
        let model = TrailingPaneHeaderModel(surface: .agentResult, contentMode: .agent, isAIEnabled: true)
        #expect(model.menuSections == [.resultView])
    }

    /// Every command in the menu acts on a row, a conversation or a session a window without a live
    /// connection does not have.
    @Test("A pane with nothing behind it offers no menu")
    func noContentNoMenu() {
        for surface in TrailingPaneSurface.allCases {
            let model = TrailingPaneHeaderModel(
                surface: surface,
                contentMode: .browse,
                isAIEnabled: true,
                hasContent: false
            )
            #expect(model.menuSections.isEmpty, "\(surface)")
        }
    }

    /// The ellipsis carries no text, so its label is the only name VoiceOver and the tooltip have.
    @Test("Each surface's menu has a name of its own")
    func menuLabelsAreDistinct() {
        let labels = TrailingPaneSurface.allCases.map {
            TrailingPaneHeaderModel(surface: $0, contentMode: .browse, isAIEnabled: true).menuLabel
        }
        #expect(Set(labels).count == labels.count)
        #expect(!labels.contains { $0.isEmpty })
    }

    /// Two unrelated histories in one window stopped sharing `clock`; the surfaces cannot share a
    /// glyph either, or the picker's segments are told apart by their tooltips alone.
    @Test("Each surface has a glyph of its own, none of them the pane's")
    func surfaceGlyphsAreDistinct() {
        let symbols = TrailingPaneSurface.allCases.map(\.symbolName)
        #expect(Set(symbols).count == symbols.count)
        #expect(!symbols.contains("sidebar.right"))
    }

    // MARK: - The view

    /// The complaint the shared header answers: switching surface changed the height of the pane's
    /// top edge, so everything under it jumped. A picker, a plain title, and no menu at all must all
    /// come out the same height.
    @Test("The header is the same height on every surface")
    func headerHeightIsConstant() {
        let paneState = TrailingPaneState()
        let heights = AIFeatureScope.enabled {
            [
                measuredHeight(TrailingPaneHeaderView(surface: .inspector, contentMode: .browse, paneState: paneState) { _ in
                    EmptyView()
                }),
                measuredHeight(TrailingPaneHeaderView(surface: .assistant, contentMode: .browse, paneState: paneState) { _ in
                    EmptyView()
                }),
                measuredHeight(TrailingPaneHeaderView(surface: .agentResult, contentMode: .agent, paneState: nil) { _ in
                    EmptyView()
                }),
                measuredHeight(TrailingPaneHeaderView(
                    surface: .inspector,
                    contentMode: .browse,
                    paneState: nil,
                    hasContent: false
                ) { _ in
                    EmptyView()
                }),
            ]
        }
        #expect(Set(heights).count == 1, "heights: \(heights)")
        #expect(heights.allSatisfy { $0 >= TrailingPaneHeaderMetrics.height })
    }

    private func measuredHeight(_ header: some View) -> CGFloat {
        let host = NSHostingView(rootView: header.frame(width: 270))
        host.frame = NSRect(x: 0, y: 0, width: 270, height: 200)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}

/// The result column's answer to what it can draw. A connection that is down is the reason no
/// session can run, so it is named as such rather than reported as an empty session list, and a
/// session that exists is drawn only over a connection that is up.
struct TrailingPaneUnavailableReasonTests {
    @Test("A live connection with no session says no session is open")
    func liveConnectionHasNoSession() {
        #expect(TrailingPaneUnavailableView.Reason.agentResult(pane: .content, hasSession: false) == .noSession)
    }

    @Test("A live connection with a session draws it")
    func liveConnectionDrawsItsSession() {
        #expect(TrailingPaneUnavailableView.Reason.agentResult(pane: .content, hasSession: true) == nil)
    }

    /// The column used to keep a session's SQL and Results over a dropped connection, statements and
    /// rows that could no longer run or be refreshed, beside a detail column already showing the
    /// unavailable screen.
    @Test("A connection that is not up says so, with or without a session", arguments: [false, true])
    func downConnectionIsNamed(hasSession: Bool) {
        let panes: [ConnectionWindowPane] = [
            .connecting,
            .unavailable(.notConnected),
            .unavailable(.disconnected(nil)),
            .empty,
        ]
        for pane in panes {
            #expect(
                TrailingPaneUnavailableView.Reason.agentResult(pane: pane, hasSession: hasSession) == .notConnected,
                "\(pane)"
            )
        }
    }
}

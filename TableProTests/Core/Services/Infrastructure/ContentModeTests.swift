//
//  ContentModeTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("Agent mode")
@MainActor
struct ContentModeTests {
    /// The one field that makes a mode toggle repaint anything. Without it the phase holds, the
    /// connection holds and the session is the same, so `syncPanes(of:)` compares equal and the
    /// window keeps drawing the mode it had already drawn.
    @Test("A pure mode toggle changes the pane render key")
    func modeChangesTheRenderKey() {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let browse = WorkspacePaneRenderKey(
            pane: .content,
            connection: connection,
            sessionRevision: 3,
            contentMode: .browse,
            agentSessionId: nil
        )
        let agent = WorkspacePaneRenderKey(
            pane: .content,
            connection: connection,
            sessionRevision: 3,
            contentMode: .agent,
            agentSessionId: nil
        )
        #expect(browse != agent)
    }

    @Test("Agent mode resolves back to browsing when the AI feature is off")
    func agentModeNeedsTheFeature() {
        #expect(ConnectionWorkspaceContentMode.resolved(.agent, isAIEnabled: false) == .browse)
        #expect(ConnectionWorkspaceContentMode.resolved(.agent, isAIEnabled: true) == .agent)
        #expect(ConnectionWorkspaceContentMode.resolved(.browse, isAIEnabled: false) == .browse)
    }

    @Test("The mode toggles between exactly two states")
    func toggling() {
        #expect(ConnectionWorkspaceContentMode.browse.toggled == .agent)
        #expect(ConnectionWorkspaceContentMode.agent.toggled == .browse)
    }

    /// The result pane belongs to the mode, not to a command, so it must never land in the stored
    /// per-connection surface preference and displace what the user chose for browsing.
    @Test("The result surface is not user-selectable and is never stored")
    func resultSurfaceIsModeOwned() {
        #expect(TrailingPaneSurface.agentResult.isUserSelectable == false)
        #expect(TrailingPaneSurface.inspector.isUserSelectable)
        #expect(TrailingPaneSurface.assistant.isUserSelectable)

        let defaults = UserDefaults(suiteName: "ContentModeTests-\(UUID().uuidString)")
        let connectionId = UUID()
        let state = TrailingPaneState(connectionId: connectionId, defaults: defaults ?? .standard)
        state.surface = .agentResult

        #expect(defaults?.string(forKey: TrailingPaneState.surfaceKey(connectionId)) == nil)
    }

    @Test("Turning the AI feature off takes every AI surface with it")
    func aiSurfacesFollowTheSetting() {
        #expect(TrailingPaneSurface.resolved(.assistant, isAIEnabled: false) == .inspector)
        #expect(TrailingPaneSurface.resolved(.agentResult, isAIEnabled: false) == .inspector)
        #expect(TrailingPaneSurface.resolved(.assistant, isAIEnabled: true) == .assistant)
    }

    // MARK: - The toolbar control

    /// Measured on macOS 27: an expanded `selectOne` group publishes a radio group whose buttons
    /// take their name from each image's `accessibilityDescription`, never from `labels:`. With nil
    /// the sidebar control announced its SF Symbol names, "List" and "favorite".
    @Test("Every toolbar segment names itself for assistive clients")
    func segmentsAreNamed() {
        let mode = MainWindowToolbar.makeContentModeGroup(target: nil, action: #selector(NSResponder.selectAll(_:)))
        let sidebar = MainWindowToolbar.makeSidebarSegmentGroup(target: nil, action: #selector(NSResponder.selectAll(_:)))

        for group in [mode, sidebar] {
            for subitem in group.subitems {
                #expect(subitem.image?.accessibilityDescription?.isEmpty == false)
            }
        }
    }

    /// The overflow menu sends an `NSMenuItem`, and reading `selectedIndex` off whatever arrived
    /// meant choosing a mode from the overflow did nothing at all.
    @Test("A segment action resolves its index from either sender")
    func segmentIndexAcceptsBothSenders() {
        let group = MainWindowToolbar.makeContentModeGroup(target: nil, action: #selector(NSResponder.selectAll(_:)))
        group.selectedIndex = 1

        let fromGroup = MainWindowToolbar.segmentIndex(from: group, group: group)
        #expect(fromGroup == 1)

        let menuItem = NSMenuItem()
        menuItem.tag = 0
        #expect(MainWindowToolbar.segmentIndex(from: menuItem, group: group) == 0)

        #expect(MainWindowToolbar.segmentIndex(from: nil, group: group) == 1)
    }

    @Test("The mode control owns an overflow menu with one item per mode")
    func menuFormHasEveryMode() throws {
        let group = MainWindowToolbar.makeContentModeGroup(target: nil, action: #selector(NSResponder.selectAll(_:)))
        let submenu = try #require(group.menuFormRepresentation?.submenu)

        #expect(submenu.items.count == ConnectionWorkspaceContentMode.allCases.count)
        for (index, item) in submenu.items.enumerated() {
            #expect(item.tag == index)
            #expect(item.title == ConnectionWorkspaceContentMode.allCases[index].localizedTitle)
        }
    }

    /// `isNavigational` lets AppKit lift an item out of its declared slot and pin it to the leading
    /// edge, which is what put the sidebar control past the sidebar divider.
    @Test("The mode control stays in the slot it was given")
    func modeControlIsNotNavigational() {
        let group = MainWindowToolbar.makeContentModeGroup(target: nil, action: #selector(NSResponder.selectAll(_:)))
        #expect(group.isNavigational == false)
        #expect(group.selectionMode == NSToolbarItemGroup.SelectionMode.selectOne)
    }
}

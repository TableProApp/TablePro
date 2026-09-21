//
//  BrowseCollapseStateOwnershipTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// What Browse had collapsed belongs to the workspace, not to the connection.
///
/// A tab torn into its own window leaves one connection hosted by two workspaces, and each window
/// has its own collapsed sidebar and inspector. Keyed by connection id in a static, the second
/// window to enter Agent mode overwrote what the first had recorded, and the first then came out of
/// the mode with the second window's layout.
@Suite("Browse collapse state ownership")
@MainActor
struct BrowseCollapseStateOwnershipTests {
    private static let connectionId = UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")

    private func makeWorkspace(_ connectionId: UUID) -> ConnectionWorkspace {
        ConnectionWorkspace(
            connectionId: connectionId,
            payload: nil,
            autoConnect: false,
            payloadConnection: nil,
            session: nil,
            sessionState: nil,
            trailingPaneState: nil,
            phase: .idle
        )
    }

    @Test("A fresh workspace has recorded nothing")
    func startsEmpty() throws {
        let connectionId = try #require(Self.connectionId)
        #expect(makeWorkspace(connectionId).browseCollapseState == nil)
    }

    @Test("Two workspaces for one connection keep separate records")
    func twoWorkspacesDoNotShareARecord() throws {
        let connectionId = try #require(Self.connectionId)
        let first = makeWorkspace(connectionId)
        let second = makeWorkspace(connectionId)

        first.browseCollapseState = (sidebar: false, inspector: true)
        second.browseCollapseState = (sidebar: true, inspector: false)

        #expect(first.browseCollapseState?.sidebar == false)
        #expect(first.browseCollapseState?.inspector == true)
        #expect(second.browseCollapseState?.sidebar == true)
        #expect(second.browseCollapseState?.inspector == false)
    }

    /// Leaving the mode hands the layout back and forgets it, so a second entry records what Browse
    /// has at that moment rather than replaying what it had the first time.
    @Test("Clearing one workspace's record leaves the other's standing")
    func clearingIsScopedToItsWorkspace() throws {
        let connectionId = try #require(Self.connectionId)
        let first = makeWorkspace(connectionId)
        let second = makeWorkspace(connectionId)
        first.browseCollapseState = (sidebar: true, inspector: true)
        second.browseCollapseState = (sidebar: false, inspector: false)

        first.browseCollapseState = nil

        #expect(first.browseCollapseState == nil)
        #expect(second.browseCollapseState?.sidebar == false)
        #expect(second.browseCollapseState?.inspector == false)
    }

    /// The mode is per connection too, so one workspace can sit in Agent mode with its columns
    /// revealed while another in the same window stays on a table with its inspector closed.
    @Test("The content mode is per workspace as well")
    func contentModeIsPerWorkspace() throws {
        let connectionId = try #require(Self.connectionId)
        let browsing = makeWorkspace(connectionId)
        let agent = makeWorkspace(connectionId)

        agent.contentMode = .agent

        #expect(browsing.contentMode == .browse)
        #expect(agent.contentMode == .agent)
    }
}

//
//  ConnectionWindowPaneResolverTests.swift
//  TableProTests
//
//  The failed-connect window used to keep painting a stale "Connecting" pane,
//  and the one rebuild path that could have replaced it resolved to an empty
//  pane instead. Both dead ends are unreachable through this resolver.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Connection window pane resolver")
struct ConnectionWindowPaneResolverTests {
    private static let failure = ConnectionFailureInfo(message: "Could not connect to the server.")

    @Test("A failed connection shows its own pane, never a spinner and never a blank window")
    func failureResolvesToUnavailablePane() {
        let pane = ConnectionWindowPaneResolver.pane(
            phase: .unavailable(.failed(Self.failure)),
            hasConnection: true,
            hasRenderableSession: false
        )

        #expect(pane == .unavailable(.failed(Self.failure)))
        #expect(pane != .connecting)
        #expect(pane != .empty)
    }

    @Test("Only a window with content earns a sidebar and an inspector")
    func chromeHiddenForEveryNonContentPane() {
        #expect(!ConnectionWindowPaneResolver.hidesChrome(for: .content))
        #expect(ConnectionWindowPaneResolver.hidesChrome(for: .connecting))
        #expect(ConnectionWindowPaneResolver.hidesChrome(for: .empty))

        let reasons: [ConnectionUnavailableReason] = [
            .notConnected,
            .cancelled,
            .disconnected(nil),
            .failed(Self.failure),
            .pluginMissing(Self.failure)
        ]
        for reason in reasons {
            #expect(ConnectionWindowPaneResolver.hidesChrome(for: .unavailable(reason)))
        }
    }

    @Test("A window hosting a rail keeps it when its own connection has nothing to show")
    func railSurvivesEveryNonContentPane() {
        let reasons: [ConnectionUnavailableReason] = [
            .notConnected,
            .cancelled,
            .disconnected(nil),
            .disconnectedByUser,
            .failed(Self.failure),
            .pluginMissing(Self.failure)
        ]
        let panes: [ConnectionWindowPane] = [.connecting, .empty] + reasons.map { .unavailable($0) }

        for pane in panes {
            #expect(ConnectionWindowPaneResolver.sidebarChromeMode(for: pane, hasRail: true) == .railOnly)
            #expect(ConnectionWindowPaneResolver.sidebarChromeMode(for: pane, hasRail: false) == .hidden)
        }
    }

    @Test("Content reveals the whole sidebar whether or not a rail is in it")
    func contentAlwaysRevealsTheSidebar() {
        #expect(ConnectionWindowPaneResolver.sidebarChromeMode(for: .content, hasRail: true) == .revealed)
        #expect(ConnectionWindowPaneResolver.sidebarChromeMode(for: .content, hasRail: false) == .revealed)
    }

    @Test("Only the revealed sidebar carries an object browser")
    func objectBrowserBelongsToTheRevealedModeAlone() {
        #expect(SidebarChromeMode.revealed.showsObjectBrowser)
        #expect(!SidebarChromeMode.railOnly.showsObjectBrowser)
        #expect(!SidebarChromeMode.hidden.showsObjectBrowser)
    }

    @Test("Every unavailable reason reaches its pane")
    func everyUnavailableReasonResolves() {
        let reasons: [ConnectionUnavailableReason] = [
            .cancelled,
            .disconnected(nil),
            .failed(Self.failure),
            .pluginMissing(Self.failure)
        ]

        for reason in reasons {
            let pane = ConnectionWindowPaneResolver.pane(
                phase: .unavailable(reason),
                hasConnection: true,
                hasRenderableSession: false
            )

            #expect(pane == .unavailable(reason))
        }
    }

    @Test("Connecting shows the spinner only while a connection is known")
    func connectingNeedsAConnection() {
        #expect(
            ConnectionWindowPaneResolver.pane(
                phase: .connecting, hasConnection: true, hasRenderableSession: false
            ) == .connecting
        )
        #expect(
            ConnectionWindowPaneResolver.pane(
                phase: .connecting, hasConnection: false, hasRenderableSession: false
            ) == .empty
        )
    }

    @Test("Connected content needs a renderable session")
    func connectedNeedsRenderableSession() {
        #expect(
            ConnectionWindowPaneResolver.pane(
                phase: .connected, hasConnection: true, hasRenderableSession: true
            ) == .content
        )
        #expect(
            ConnectionWindowPaneResolver.pane(
                phase: .connected, hasConnection: true, hasRenderableSession: false
            ) == .empty
        )
    }

    @Test("A restored window that has not connected yet offers to connect")
    func idleWithConnectionOffersToConnect() {
        #expect(
            ConnectionWindowPaneResolver.pane(
                phase: .idle, hasConnection: true, hasRenderableSession: false
            ) == .unavailable(.notConnected)
        )
        #expect(
            ConnectionWindowPaneResolver.pane(
                phase: .idle, hasConnection: false, hasRenderableSession: false
            ) == .empty
        )
        #expect(
            ConnectionWindowPaneResolver.pane(
                phase: .idle, hasConnection: true, hasRenderableSession: true
            ) == .content
        )
    }

    @Test("A closing window renders nothing whatever its session looks like")
    func closingIsAlwaysEmpty() {
        for hasConnection in [true, false] {
            for hasRenderableSession in [true, false] {
                let pane = ConnectionWindowPaneResolver.pane(
                    phase: .closing,
                    hasConnection: hasConnection,
                    hasRenderableSession: hasRenderableSession
                )

                #expect(pane == .empty)
            }
        }
    }

    @Test("No combination of inputs shows a spinner for a phase that is not connecting")
    func spinnerOnlyForConnecting() {
        let phases: [ConnectionWindowPhase] = [
            .idle,
            .connected,
            .closing,
            .unavailable(.cancelled),
            .unavailable(.disconnected(nil)),
            .unavailable(.failed(Self.failure)),
            .unavailable(.pluginMissing(Self.failure))
        ]

        for phase in phases {
            for hasConnection in [true, false] {
                for hasRenderableSession in [true, false] {
                    let pane = ConnectionWindowPaneResolver.pane(
                        phase: phase,
                        hasConnection: hasConnection,
                        hasRenderableSession: hasRenderableSession
                    )

                    #expect(pane != .connecting, "\(phase) must never resolve to a spinner")
                }
            }
        }
    }

    @Test("The tab strip band appears only for content with more than one tab")
    func tabStripBandFollowsContentAndTabCount() {
        #expect(ConnectionWindowPaneResolver.showsTabStrip(for: .content, tabCount: 2))
        #expect(ConnectionWindowPaneResolver.showsTabStrip(for: .content, tabCount: 9))

        /// A single tab is the window every connection opens with, and it gained no chrome
        /// before this band existed.
        #expect(!ConnectionWindowPaneResolver.showsTabStrip(for: .content, tabCount: 1))
        #expect(!ConnectionWindowPaneResolver.showsTabStrip(for: .content, tabCount: 0))
    }

    @Test("A pane with no session behind it shows no tab strip, whatever the stale tab count says")
    func tabStripBandHiddenWithoutContent() {
        for pane in [
            ConnectionWindowPane.connecting,
            .unavailable(.notConnected),
            .unavailable(.failed(Self.failure)),
            .empty,
        ] {
            #expect(!ConnectionWindowPaneResolver.showsTabStrip(for: pane, tabCount: 5))
        }
    }
}

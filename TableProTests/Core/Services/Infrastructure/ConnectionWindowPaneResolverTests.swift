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

    private static let everyUnavailableReason: [ConnectionUnavailableReason] = [
        .notConnected,
        .cancelled,
        .disconnected(nil),
        .disconnectedByUser,
        .failed(failure),
        .pluginMissing(failure)
    ]

    private static let everyPane: [ConnectionWindowPane] =
        [.content, .preparing, .connecting, .empty] + everyUnavailableReason.map { .unavailable($0) }

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

    @Test("A wait the user can see costs the chrome; one they cannot does not")
    func chromeHiddenForEveryNonContentPaneExceptPreparing() {
        #expect(!ConnectionWindowPaneResolver.hidesChrome(for: .content))
        #expect(
            !ConnectionWindowPaneResolver.hidesChrome(for: .preparing),
            "collapsing for a 40ms connect only to put it back is the flash the pane exists to stop"
        )
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

    @Test("A lone workspace never earns a strip, whatever its pane is doing")
    func stripNeedsSomewhereToGo() {
        for count in [0, 1] {
            for pane in Self.everyPane {
                #expect(!ConnectionWindowPaneResolver.showsWorkspaceRail(
                    preferenceEnabled: true,
                    workspaceCount: count,
                    pane: pane,
                    isClosing: false
                ))
            }
        }
    }

    @Test("The preference governs the strip while the window still has content behind it")
    func preferenceGovernsTheStripOverContent() {
        #expect(ConnectionWindowPaneResolver.showsWorkspaceRail(
            preferenceEnabled: true,
            workspaceCount: 2,
            pane: .content,
            isClosing: false
        ))
        #expect(!ConnectionWindowPaneResolver.showsWorkspaceRail(
            preferenceEnabled: false,
            workspaceCount: 2,
            pane: .content,
            isClosing: false
        ))
    }

    /// The pane that hides the object browser, the tab strip and the connection-scoped toolbar
    /// items leaves the strip as the only thing on screen naming the window's other connections,
    /// so a preference cannot take it too.
    @Test("A connection with nothing to show brings the strip back over the preference")
    func stripOutlivesThePreferenceWhenItIsTheOnlyRouteOut() {
        let stranding: [ConnectionWindowPane] = [.connecting] + Self.everyUnavailableReason.map { .unavailable($0) }

        for pane in stranding {
            #expect(ConnectionWindowPaneResolver.showsWorkspaceRail(
                preferenceEnabled: false,
                workspaceCount: 2,
                pane: pane,
                isClosing: false
            ))
            #expect(ConnectionWindowPaneResolver.showsWorkspaceRail(
                preferenceEnabled: true,
                workspaceCount: 2,
                pane: pane,
                isClosing: false
            ))
        }
    }

    /// Every pane that takes the window's chrome away is one the strip has to outlive, 
    /// included: a workspace whose connection never resolved lands there without closing anything.
    @Test("A chrome-hiding empty pane brings the strip back like any other")
    func emptyPaneIsNotAnException() {
        #expect(ConnectionWindowPaneResolver.showsWorkspaceRail(
            preferenceEnabled: false,
            workspaceCount: 2,
            pane: .empty,
            isClosing: false
        ))
    }

    /// Closing cannot be read off the pane, because a closing window and a workspace with no
    /// connection resolve to the same one. Laying a switcher over a window that is going away is
    /// the mistake at that end.
    @Test("A closing window is given no strip, whatever its pane resolved to")
    func closingWindowNeverGainsAStrip() {
        for pane in Self.everyPane {
            #expect(!ConnectionWindowPaneResolver.showsWorkspaceRail(
                preferenceEnabled: true,
                workspaceCount: 2,
                pane: pane,
                isClosing: true
            ))
        }
    }

    @Test("Only the revealed sidebar carries an object browser")
    func objectBrowserBelongsToTheRevealedModeAlone() {
        #expect(SidebarChromeMode.revealed.showsObjectBrowser)
        #expect(!SidebarChromeMode.railOnly.showsObjectBrowser)
        #expect(!SidebarChromeMode.hidden.showsObjectBrowser)
    }

    // MARK: - The grace

    @Test("A connect too young to report shows nothing rather than a card")
    func connectingInsideTheGraceIsPreparing() {
        let pane = ConnectionWindowPaneResolver.pane(
            phase: .connecting,
            hasConnection: true,
            hasRenderableSession: false,
            hasOutlastedGrace: false
        )

        #expect(pane == .preparing)
    }

    @Test("A connect that outlasts the grace gets its card back, Cancel and all")
    func connectingPastTheGraceIsUnchanged() {
        let pane = ConnectionWindowPaneResolver.pane(
            phase: .connecting,
            hasConnection: true,
            hasRenderableSession: false,
            hasOutlastedGrace: true
        )

        #expect(pane == .connecting)
    }

    /// `.idle` answers for a window that has finished dialling and for one that has not begun, and
    /// only the caller knows which. Reporting the second as "not connected" is what put a pane on
    /// screen for 38ms before the connecting one it was replaced by.
    @Test("A window about to dial is not a window that failed to")
    func idleAwaitingAutoConnectIsPreparing() {
        let pane = ConnectionWindowPaneResolver.pane(
            phase: .idle,
            hasConnection: true,
            hasRenderableSession: false,
            awaitsAutoConnect: true,
            hasOutlastedGrace: false
        )

        #expect(pane == .preparing)
    }

    /// The exit from `.preparing`. `startActivationConnectIfNeeded` returns without dialling when
    /// the phase disallows it or the connection record has gone, and without this the window would
    /// sit blank with no route out.
    @Test("A dial that never starts falls back to the not-connected pane once the grace expires")
    func idleThatNeverDialledResolvesOnceTheGraceExpires() {
        let pane = ConnectionWindowPaneResolver.pane(
            phase: .idle,
            hasConnection: true,
            hasRenderableSession: false,
            awaitsAutoConnect: true,
            hasOutlastedGrace: true
        )

        #expect(pane == .unavailable(.notConnected))
    }

    @Test("A window the user has to connect by hand says so at once")
    func idleWithoutAutoConnectNeverPrepares() {
        for hasOutlastedGrace in [false, true] {
            let pane = ConnectionWindowPaneResolver.pane(
                phase: .idle,
                hasConnection: true,
                hasRenderableSession: false,
                awaitsAutoConnect: false,
                hasOutlastedGrace: hasOutlastedGrace
            )

            #expect(pane == .unavailable(.notConnected))
        }
    }

    /// The grace may not delay a failure. A server that refuses in 20ms is an answer, not a wait.
    @Test("The grace never holds back a settled outcome")
    func settledPhasesIgnoreTheGrace() {
        for hasOutlastedGrace in [false, true] {
            #expect(ConnectionWindowPaneResolver.pane(
                phase: .unavailable(.failed(Self.failure)),
                hasConnection: true,
                hasRenderableSession: false,
                awaitsAutoConnect: true,
                hasOutlastedGrace: hasOutlastedGrace
            ) == .unavailable(.failed(Self.failure)))

            #expect(ConnectionWindowPaneResolver.pane(
                phase: .connected,
                hasConnection: true,
                hasRenderableSession: true,
                awaitsAutoConnect: true,
                hasOutlastedGrace: hasOutlastedGrace
            ) == .content)

            #expect(ConnectionWindowPaneResolver.pane(
                phase: .closing,
                hasConnection: true,
                hasRenderableSession: true,
                awaitsAutoConnect: true,
                hasOutlastedGrace: hasOutlastedGrace
            ) == .empty)
        }
    }

    @Test("The timer runs over exactly the phases the grace can answer differently")
    func graceIsArmedForDiallingPhasesAlone() {
        #expect(ConnectionWindowPaneResolver.awaitsProgressGrace(phase: .connecting, awaitsAutoConnect: false))
        #expect(ConnectionWindowPaneResolver.awaitsProgressGrace(phase: .idle, awaitsAutoConnect: true))
        #expect(!ConnectionWindowPaneResolver.awaitsProgressGrace(phase: .idle, awaitsAutoConnect: false))
        #expect(!ConnectionWindowPaneResolver.awaitsProgressGrace(phase: .connected, awaitsAutoConnect: true))
        #expect(!ConnectionWindowPaneResolver.awaitsProgressGrace(phase: .closing, awaitsAutoConnect: true))
        #expect(!ConnectionWindowPaneResolver.awaitsProgressGrace(
            phase: .unavailable(.failed(Self.failure)),
            awaitsAutoConnect: true
        ))
    }

    /// A window with no connection record has nothing to prepare for, so the grace cannot turn an
    /// empty window into one that looks like it is working.
    @Test("Preparing needs a connection to be preparing for")
    func noConnectionStaysEmptyThroughTheGrace() {
        #expect(ConnectionWindowPaneResolver.pane(
            phase: .connecting,
            hasConnection: false,
            hasRenderableSession: false,
            hasOutlastedGrace: false
        ) == .empty)

        #expect(ConnectionWindowPaneResolver.pane(
            phase: .idle,
            hasConnection: false,
            hasRenderableSession: false,
            awaitsAutoConnect: true,
            hasOutlastedGrace: false
        ) == .empty)
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

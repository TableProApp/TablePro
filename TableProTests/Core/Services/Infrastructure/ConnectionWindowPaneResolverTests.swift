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
        [.content, .connecting, .empty] + everyUnavailableReason.map { .unavailable($0) }

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

    /// The pane used to decide whether the window had a sidebar and an inspector at all, which is
    /// what made a connect slower than half a second rebuild the window twice. It answers for the
    /// detail pane's content and for nothing else now; the only thing left reading it is the strip,
    /// through this one property.
    @Test("Only content counts as content")
    func onlyContentHasContent() {
        #expect(ConnectionWindowPane.content.hasContent)
        #expect(!ConnectionWindowPane.connecting.hasContent)
        #expect(!ConnectionWindowPane.empty.hasContent)

        for reason in Self.everyUnavailableReason {
            #expect(!ConnectionWindowPane.unavailable(reason).hasContent)
        }
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

    // MARK: - Dialling

    /// There is no timer in here any more. A connect reports itself from the moment it starts, and
    /// the wait that decides whether a card is ever drawn lives in the view, where it changes what
    /// is revealed rather than what the window is built from.
    @Test("A connect resolves to its own pane from the first frame")
    func connectingResolvesImmediately() {
        #expect(ConnectionWindowPaneResolver.pane(
            phase: .connecting,
            hasConnection: true,
            hasRenderableSession: false
        ) == .connecting)
    }

    /// `.idle` answers for a window that has finished dialling and for one that has not begun, and
    /// only the caller knows which. `awaitsAutoConnect` is that answer, known when the workspace is
    /// built, so the window says it is coming up instead of reporting a failure that has not
    /// happened and then correcting itself half a second later.
    @Test("A window about to dial is not a window that failed to")
    func idleAwaitingAutoConnectIsConnecting() {
        #expect(ConnectionWindowPaneResolver.pane(
            phase: .idle,
            hasConnection: true,
            hasRenderableSession: false,
            awaitsAutoConnect: true
        ) == .connecting)
    }

    @Test("A window the user has to connect by hand says so at once")
    func idleWithoutAutoConnectOffersToConnect() {
        #expect(ConnectionWindowPaneResolver.pane(
            phase: .idle,
            hasConnection: true,
            hasRenderableSession: false,
            awaitsAutoConnect: false
        ) == .unavailable(.notConnected))
    }

    /// A session that is already up outranks the intent to dial, so a window adopting one never
    /// shows a connecting card over content it already has.
    @Test("A renderable session outranks the intent to dial")
    func renderableSessionWinsOverAutoConnect() {
        #expect(ConnectionWindowPaneResolver.pane(
            phase: .idle,
            hasConnection: true,
            hasRenderableSession: true,
            awaitsAutoConnect: true
        ) == .content)
    }

    /// A window with no connection record has nothing to dial, so the intent cannot turn an empty
    /// window into one that looks like it is working.
    @Test("Connecting needs a connection to be connecting to")
    func noConnectionStaysEmpty() {
        #expect(ConnectionWindowPaneResolver.pane(
            phase: .connecting,
            hasConnection: false,
            hasRenderableSession: false
        ) == .empty)

        #expect(ConnectionWindowPaneResolver.pane(
            phase: .idle,
            hasConnection: false,
            hasRenderableSession: false,
            awaitsAutoConnect: true
        ) == .empty)
    }

    /// A server that refuses in 20ms is an answer, not a wait, and the intent to dial cannot hold
    /// a settled phase back.
    @Test("A settled phase ignores the intent to dial")
    func settledPhasesIgnoreTheIntentToDial() {
        #expect(ConnectionWindowPaneResolver.pane(
            phase: .unavailable(.failed(Self.failure)),
            hasConnection: true,
            hasRenderableSession: false,
            awaitsAutoConnect: true
        ) == .unavailable(.failed(Self.failure)))

        #expect(ConnectionWindowPaneResolver.pane(
            phase: .connected,
            hasConnection: true,
            hasRenderableSession: true,
            awaitsAutoConnect: true
        ) == .content)

        #expect(ConnectionWindowPaneResolver.pane(
            phase: .closing,
            hasConnection: true,
            hasRenderableSession: true,
            awaitsAutoConnect: true
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

    /// `.idle` is left out on purpose: it is the one phase that can resolve to a card, and only
    /// for a window whose intent to dial is already recorded. Its own rules are above.
    @Test("No combination of inputs shows a spinner for a phase that is not connecting")
    func spinnerOnlyForConnecting() {
        let phases: [ConnectionWindowPhase] = [
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
                    for awaitsAutoConnect in [true, false] {
                        let pane = ConnectionWindowPaneResolver.pane(
                            phase: phase,
                            hasConnection: hasConnection,
                            hasRenderableSession: hasRenderableSession,
                            awaitsAutoConnect: awaitsAutoConnect
                        )

                        #expect(pane != .connecting, "\(phase) must never resolve to a spinner")
                    }
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

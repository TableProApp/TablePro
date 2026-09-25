//
//  TrailingPaneSurfaceResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TrailingPaneSurfaceResolverTests {
    @Test(
        "Agent mode draws the result pane whatever the user last chose",
        arguments: TrailingPaneSurface.allCases
    )
    func agentModeImposesTheResult(stored: TrailingPaneSurface) {
        #expect(
            TrailingPaneSurfaceResolver.resolve(stored: stored, contentMode: .agent, isAIEnabled: true)
                == .agentResult
        )
    }

    @Test("Browsing draws the surface the user chose")
    func browsingHonoursTheStoredSurface() {
        #expect(
            TrailingPaneSurfaceResolver.resolve(stored: .inspector, contentMode: .browse, isAIEnabled: true)
                == .inspector
        )
        #expect(
            TrailingPaneSurfaceResolver.resolve(stored: .assistant, contentMode: .browse, isAIEnabled: true)
                == .assistant
        )
    }

    /// The assistant is the one surface a setting can take away, and the stored value is restored
    /// per connection without anything asking whether the surface still exists.
    @Test("With AI off, every surface resolves to the inspector", arguments: TrailingPaneSurface.allCases)
    func aiOffFallsBackToTheInspector(stored: TrailingPaneSurface) {
        #expect(
            TrailingPaneSurfaceResolver.resolve(stored: stored, contentMode: .browse, isAIEnabled: false)
                == .inspector
        )
    }

    /// Agent mode is the AI feature, so a window left in it with the setting off is browsing, and
    /// its pane must not go on drawing a result the mode no longer imposes.
    @Test("Agent mode with AI off resolves as browsing", arguments: TrailingPaneSurface.allCases)
    func agentModeWithAIOffResolvesAsBrowsing(stored: TrailingPaneSurface) {
        #expect(
            TrailingPaneSurfaceResolver.resolve(stored: stored, contentMode: .agent, isAIEnabled: false)
                == .inspector
        )
    }

    @Test("The header offers both surfaces while browsing with AI on")
    func selectableWhileBrowsing() {
        #expect(
            TrailingPaneSurfaceResolver.selectable(contentMode: .browse, isAIEnabled: true)
                == [.inspector, .assistant]
        )
        #expect(
            TrailingPaneSurfaceResolver.selectable(contentMode: .browse, isAIEnabled: false) == [.inspector]
        )
    }

    /// Empty rather than one segment: the mode chose, so the header draws a plain title.
    @Test("The header offers nothing to choose in Agent mode")
    func selectableInAgentMode() {
        #expect(TrailingPaneSurfaceResolver.selectable(contentMode: .agent, isAIEnabled: true).isEmpty)
    }

    @Test("A resolved surface is one the header offers, unless the mode imposed it")
    func resolvedSurfaceIsOffered() {
        for mode in ConnectionWorkspaceContentMode.allCases {
            for aiEnabled in [true, false] {
                for stored in TrailingPaneSurface.allCases {
                    let resolved = TrailingPaneSurfaceResolver.resolve(
                        stored: stored,
                        contentMode: mode,
                        isAIEnabled: aiEnabled
                    )
                    let offered = TrailingPaneSurfaceResolver.selectable(
                        contentMode: mode,
                        isAIEnabled: aiEnabled
                    )
                    let imposed = offered.isEmpty && resolved == .agentResult
                    #expect(imposed || offered.contains(resolved))
                }
            }
        }
    }

    /// A command that revealed the pane for a surface it will not draw opened it on another one.
    @Test("Only the surface a mode and setting allow is drawn when asked for")
    func drawsOnlyWhatTheModeAllows() {
        for mode in ConnectionWorkspaceContentMode.allCases {
            for aiEnabled in [true, false] {
                for surface in TrailingPaneSurface.allCases {
                    let drawn = TrailingPaneSurfaceResolver.resolve(
                        stored: surface,
                        contentMode: mode,
                        isAIEnabled: aiEnabled
                    )
                    #expect(
                        TrailingPaneSurfaceResolver.draws(surface, contentMode: mode, isAIEnabled: aiEnabled)
                            == (drawn == surface),
                        "\(mode) ai=\(aiEnabled) \(surface)"
                    )
                }
            }
        }
        #expect(TrailingPaneSurfaceResolver.draws(.agentResult, contentMode: .agent, isAIEnabled: true))
        #expect(!TrailingPaneSurfaceResolver.draws(.inspector, contentMode: .agent, isAIEnabled: true))
        #expect(!TrailingPaneSurfaceResolver.draws(.assistant, contentMode: .browse, isAIEnabled: false))
    }

    /// The result pane belongs to a mode rather than to a command, so it never reaches the stored
    /// per-connection preference and never appears in the header's choices.
    @Test("The result surface is never user selectable")
    func resultIsNeverSelectable() {
        #expect(TrailingPaneSurface.agentResult.isUserSelectable == false)
        for mode in ConnectionWorkspaceContentMode.allCases {
            #expect(
                TrailingPaneSurfaceResolver.selectable(contentMode: mode, isAIEnabled: true)
                    .contains(.agentResult) == false
            )
        }
    }
}

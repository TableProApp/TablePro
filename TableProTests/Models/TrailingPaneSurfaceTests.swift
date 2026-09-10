//
//  TrailingPaneSurfaceTests.swift
//  TableProTests
//
//  The surface is persisted per connection and restored without asking whether it still exists, so
//  a connection last left on the assistant comes back to it with the assistant turned off.
//

import Foundation
import Testing

@testable import TablePro

@Suite("Trailing pane surface")
struct TrailingPaneSurfaceTests {
    @Test("The assistant is the only surface a setting takes away")
    func assistantIsTheOnlyOptionalSurface() {
        #expect(TrailingPaneSurface.resolved(.assistant, isAIEnabled: false) == .inspector)
        #expect(TrailingPaneSurface.resolved(.assistant, isAIEnabled: true) == .assistant)
    }

    @Test("The inspector resolves to itself either way")
    func inspectorIsUntouched() {
        for enabled in [true, false] {
            #expect(TrailingPaneSurface.resolved(.inspector, isAIEnabled: enabled) == .inspector)
        }
    }

    @Test("A resolved surface is never one the settings have taken away")
    func resolutionIsAlwaysReachable() {
        for surface in TrailingPaneSurface.allCases {
            #expect(TrailingPaneSurface.resolved(surface, isAIEnabled: false) != .assistant)
        }
    }

    @Test("Every surface has a title")
    func everySurfaceIsNamed() {
        for surface in TrailingPaneSurface.allCases {
            #expect(!surface.localizedTitle.isEmpty)
        }
    }
}

@Suite("Inspector view mode")
struct InspectorViewModeTests {
    /// Both modes are renderings of one selection, which is what makes a segmented control the
    /// right control for them. The assistant used to be a third case here.
    @Test("The inspector offers exactly its two renderings of the selected row")
    func offersTwoRenderings() {
        #expect(InspectorViewMode.allCases == [.fields, .json])
    }

    @Test("Every mode has a title")
    func everyModeIsNamed() {
        for mode in InspectorViewMode.allCases {
            #expect(!mode.localizedTitle.isEmpty)
        }
    }
}

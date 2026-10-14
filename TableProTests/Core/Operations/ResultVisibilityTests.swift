//
//  ResultVisibilityTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

struct ResultVisibilityTests {
    @Test("A result counts as on screen only when all three axes agree")
    func allThreeAxesMustAgree() {
        #expect(ResultVisibility.onScreen.resultIsOnScreen)
        #expect(!ResultVisibility.offScreen.resultIsOnScreen)
        #expect(!ResultVisibility(
            appIsActive: true, ownerWindowIsVisible: true, ownerIsSelectedInWindow: false
        ).resultIsOnScreen)
    }

    /// Measured on macOS 27: a visible window reports 8194 and an occluded or minimized one 8192,
    /// while `.visible` is 1 << 1. Equality is therefore always false, and a gate written with
    /// `==` notifies for every result including the one the user is looking at.
    @Test("Occlusion is a membership test, never an equality test")
    func occlusionIsMembershipNotEquality() {
        let visible = NSWindow.OcclusionState(rawValue: 8194)
        #expect(visible.contains(.visible))
        #expect(visible != .visible)

        let occluded = NSWindow.OcclusionState(rawValue: 8192)
        #expect(!occluded.contains(.visible))
        #expect(occluded != .visible)
    }
}

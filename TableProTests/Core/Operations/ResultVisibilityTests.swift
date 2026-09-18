//
//  ResultVisibilityTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Result visibility")
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

    /// Source-scanned rather than behavioural, because reproducing a covered window in a unit test
    /// needs a real window server. The rule above is the one that breaks silently.
    @Test("The resolver never compares occlusionState for equality")
    func resolverUsesMembership() throws {
        let source = try #require(Self.resolverSource)
        /// Comments are stripped first: the resolver's own doc comment names the wrong form in
        /// order to warn about it, and scanning the raw file flags that as a violation.
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("occlusionState.contains(.visible)"))
        #expect(!code.contains("occlusionState == .visible"))
        #expect(!code.contains("occlusionState != .visible"))
    }

    private static var resolverSource: String? {
        var directory = URL(fileURLWithPath: #filePath)
        let relative = "TablePro/Core/Services/Operations/ResultVisibilityResolver.swift"
        for _ in 0 ..< 8 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent(relative)
            if let contents = try? String(contentsOf: candidate, encoding: .utf8) { return contents }
        }
        return nil
    }
}

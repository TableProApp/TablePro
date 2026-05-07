//
//  WindowFramePolicyTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

@MainActor
@Suite("WindowFramePolicy.FirstRunSizing.contentSize")
struct WindowFramePolicyFirstRunSizingTests {
    @Test("preserveContentSize returns nil regardless of screen size")
    func preserveContentSizeReturnsNil() {
        let sizing = WindowFramePolicy.FirstRunSizing.preserveContentSize
        let smallScreen = NSRect(x: 0, y: 0, width: 800, height: 600)
        let largeScreen = NSRect(x: 0, y: 0, width: 5_120, height: 2_880)

        #expect(sizing.contentSize(for: smallScreen) == nil)
        #expect(sizing.contentSize(for: largeScreen) == nil)
    }

    @Test("fractionOfMainScreen scales width and height by the fraction")
    func fractionScalesByScreen() {
        let sizing = WindowFramePolicy.FirstRunSizing.fractionOfMainScreen(
            fraction: CGSize(width: 0.5, height: 0.5),
            minimum: NSSize(width: 100, height: 100),
            maximum: nil
        )
        let screen = NSRect(x: 0, y: 0, width: 1_600, height: 1_000)

        let result = sizing.contentSize(for: screen)
        #expect(result == NSSize(width: 800, height: 500))
    }

    @Test("minimum size floor is honored when fraction would go below it")
    func minimumIsHonored() {
        let sizing = WindowFramePolicy.FirstRunSizing.fractionOfMainScreen(
            fraction: CGSize(width: 0.5, height: 0.5),
            minimum: NSSize(width: 1_200, height: 800),
            maximum: nil
        )
        let smallScreen = NSRect(x: 0, y: 0, width: 1_400, height: 900)

        let result = sizing.contentSize(for: smallScreen)
        #expect(result == NSSize(width: 1_200, height: 800))
    }

    @Test("minimum may exceed screen but result is then clamped to screen")
    func minimumClampsToScreenWhenScreenIsTooSmall() {
        let sizing = WindowFramePolicy.FirstRunSizing.fractionOfMainScreen(
            fraction: CGSize(width: 0.85, height: 0.85),
            minimum: NSSize(width: 1_200, height: 800),
            maximum: nil
        )
        let tinyScreen = NSRect(x: 0, y: 0, width: 1_000, height: 700)

        let result = sizing.contentSize(for: tinyScreen)
        #expect(result == NSSize(width: 1_000, height: 700))
    }

    @Test("maximum size cap is honored when fraction would exceed it")
    func maximumIsHonored() {
        let sizing = WindowFramePolicy.FirstRunSizing.fractionOfMainScreen(
            fraction: CGSize(width: 0.9, height: 0.9),
            minimum: NSSize(width: 100, height: 100),
            maximum: NSSize(width: 1_100, height: 900)
        )
        let bigScreen = NSRect(x: 0, y: 0, width: 5_120, height: 2_880)

        let result = sizing.contentSize(for: bigScreen)
        #expect(result == NSSize(width: 1_100, height: 900))
    }

    @Test("editor policy on a 1440x900 display yields ~85% sized content")
    func editorPolicyOnLaptopDisplay() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let result = WindowFramePolicy.editor.firstRunSizing.contentSize(for: screen)

        #expect(result?.width == 1_224)
        #expect(result?.height == 800)
    }

    @Test("editor policy on a 5120x2880 display still yields exactly 85% (no max)")
    func editorPolicyOnRetinaDisplay() {
        let screen = NSRect(x: 0, y: 0, width: 5_120, height: 2_880)
        let result = WindowFramePolicy.editor.firstRunSizing.contentSize(for: screen)

        #expect(result?.width == 4_352)
        #expect(result?.height == 2_448)
    }

    @Test("integrationsActivity policy caps at maximum on big displays")
    func integrationsActivityCapsAtMaximum() {
        let screen = NSRect(x: 0, y: 0, width: 5_120, height: 2_880)
        let result = WindowFramePolicy.integrationsActivity.firstRunSizing.contentSize(for: screen)

        #expect(result == NSSize(width: 1_400, height: 1_000))
    }

    @Test("feedback policy preserves content size")
    func feedbackPreservesContentSize() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        #expect(WindowFramePolicy.feedback.firstRunSizing.contentSize(for: screen) == nil)
    }
}

//
//  JumpToColumnMenuValidationTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@Suite("Jump to Column menu validation")
@MainActor
struct JumpToColumnMenuValidationTests {
    private let selector = #selector(MainSplitViewController.jumpToColumn(_:))

    @Test("The item lights only over a connected window whose grid has columns to list")
    func enabledOnlyWithAConnectedGrid() {
        var context = MenuValidationContext()
        #expect(!MainSplitViewController.isEnabled(selector, context: context))

        context.isConnected = true
        #expect(!MainSplitViewController.isEnabled(selector, context: context))

        context.canJumpToColumn = true
        #expect(MainSplitViewController.isEnabled(selector, context: context))

        context.isConnected = false
        #expect(!MainSplitViewController.isEnabled(selector, context: context))
    }
}

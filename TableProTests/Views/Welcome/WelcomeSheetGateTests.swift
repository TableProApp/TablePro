//
//  WelcomeSheetGateTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("WelcomeSheetGate")
struct WelcomeSheetGateTests {
    @Test("A first launch shows the sheet")
    func firstLaunch() {
        #expect(WelcomeSheetGate.shouldPresent(hasSeen: false, isUITestSandbox: false, uiTestRequestsSheet: false))
    }

    @Test("A sheet already seen never shows on its own again")
    func seenSheet() {
        #expect(!WelcomeSheetGate.shouldPresent(hasSeen: true, isUITestSandbox: false, uiTestRequestsSheet: false))
        #expect(!WelcomeSheetGate.shouldPresent(hasSeen: true, isUITestSandbox: true, uiTestRequestsSheet: true))
    }

    @Test("A UI test sandbox keeps the sheet out of the way unless the test asks for it")
    func uiTestSandbox() {
        #expect(!WelcomeSheetGate.shouldPresent(hasSeen: false, isUITestSandbox: true, uiTestRequestsSheet: false))
        #expect(WelcomeSheetGate.shouldPresent(hasSeen: false, isUITestSandbox: true, uiTestRequestsSheet: true))
    }
}

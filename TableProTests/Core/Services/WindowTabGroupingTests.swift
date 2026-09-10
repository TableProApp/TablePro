//
//  WindowTabGroupingTests.swift
//  TableProTests
//

import AppKit
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("WindowTabGrouping")
@MainActor
struct WindowTabGroupingTests {
    /// Every app window shares one identifier. A per-connection identifier is what stopped two
    /// connections from ever sharing a window, and it is what left Merge All Windows unable to
    /// fold two connection windows together.
    @Test("Every main window shares one tabbing identifier")
    func mainWindowsShareOneIdentifier() {
        #expect(WindowManager.mainTabbingIdentifier == "com.TablePro.main")
    }

    @Test("A main window is recognised by its identifier prefix")
    func mainWindowIdentification() {
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier("main")
        #expect(WindowManager.isMainWindow(window))

        window.identifier = NSUserInterfaceItemIdentifier("main-inspector")
        #expect(WindowManager.isMainWindow(window))

        window.identifier = NSUserInterfaceItemIdentifier("welcome")
        #expect(WindowManager.isMainWindow(window) == false)
    }
}

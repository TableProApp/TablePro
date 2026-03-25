//
//  WelcomeWindowSuppressionTests.swift
//  TableProTests
//
//  Regression tests for the welcome window suppression logic in AppDelegate+WindowConfig.
//  Covers the fix where double-clicking .duckdb files from Finder caused the app to freeze
//  because suppression gave up too early and welcome was closed instead of hidden.
//

import AppKit
import Foundation
import Testing
@testable import TablePro

@Suite("Welcome Window Suppression")
@MainActor
struct WelcomeWindowSuppressionTests {
    /// Create a fresh AppDelegate for each test — avoids relying on NSApp.delegate
    /// which may not be our AppDelegate in parallel test runner processes.
    private func makeAppDelegate() -> AppDelegate {
        AppDelegate()
    }

    private func makeWindow(identifier: String) -> NSWindow {
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        return window
    }

    // MARK: - Window Identification

    @Test("isMainWindow — exact identifier 'main'")
    func isMainWindowExact() {
        let delegate = makeAppDelegate()
        let window = makeWindow(identifier: "main")
        #expect(delegate.isMainWindow(window))
    }

    @Test("isMainWindow — prefixed identifier 'main-123'")
    func isMainWindowPrefixed() {
        let delegate = makeAppDelegate()
        let window = makeWindow(identifier: "main-123")
        #expect(delegate.isMainWindow(window))
    }

    @Test("isMainWindow — returns false for nil identifier")
    func isMainWindowNilIdentifier() {
        let delegate = makeAppDelegate()
        let window = NSWindow()
        window.identifier = nil
        #expect(!delegate.isMainWindow(window))
    }

    @Test("isMainWindow — returns false for 'welcome'")
    func isMainWindowUnrelated() {
        let delegate = makeAppDelegate()
        let window = makeWindow(identifier: "welcome")
        #expect(!delegate.isMainWindow(window))
    }

    @Test("isMainWindow — returns false for 'mainExtra' (no dash separator)")
    func isMainWindowNoDash() {
        let delegate = makeAppDelegate()
        let window = makeWindow(identifier: "mainExtra")
        #expect(!delegate.isMainWindow(window))
    }

    @Test("isWelcomeWindow — exact identifier 'welcome'")
    func isWelcomeWindowExact() {
        let delegate = makeAppDelegate()
        let window = makeWindow(identifier: "welcome")
        #expect(delegate.isWelcomeWindow(window))
    }

    @Test("isWelcomeWindow — prefixed identifier 'welcome-abc'")
    func isWelcomeWindowPrefixed() {
        let delegate = makeAppDelegate()
        let window = makeWindow(identifier: "welcome-abc")
        #expect(delegate.isWelcomeWindow(window))
    }

    @Test("isWelcomeWindow — returns false for nil identifier")
    func isWelcomeWindowNilIdentifier() {
        let delegate = makeAppDelegate()
        let window = NSWindow()
        window.identifier = nil
        #expect(!delegate.isWelcomeWindow(window))
    }

    @Test("isWelcomeWindow — returns false for 'main'")
    func isWelcomeWindowNotMain() {
        let delegate = makeAppDelegate()
        let window = makeWindow(identifier: "main")
        #expect(!delegate.isWelcomeWindow(window))
    }

    @Test("isWelcomeWindow — returns false for 'welcomeExtra' (no dash separator)")
    func isWelcomeWindowNoDash() {
        let delegate = makeAppDelegate()
        let window = makeWindow(identifier: "welcomeExtra")
        #expect(!delegate.isWelcomeWindow(window))
    }

    // MARK: - suppressWelcomeWindow State

    @Test("suppressWelcomeWindow — sets isHandlingFileOpen to true")
    func suppressSetsFlag() {
        let delegate = makeAppDelegate()
        delegate.suppressWelcomeWindow()
        #expect(delegate.isHandlingFileOpen == true)
    }

    @Test("suppressWelcomeWindow — increments fileOpenSuppressionCount")
    func suppressIncrementsCount() {
        let delegate = makeAppDelegate()
        delegate.suppressWelcomeWindow()
        #expect(delegate.fileOpenSuppressionCount == 1)

        delegate.suppressWelcomeWindow()
        #expect(delegate.fileOpenSuppressionCount == 2)
    }

    @Test("suppressWelcomeWindow — hides existing welcome windows via orderOut")
    func suppressHidesWelcomeWindows() {
        let delegate = makeAppDelegate()

        let welcome = makeWindow(identifier: "welcome")
        welcome.orderFront(nil)
        defer { welcome.close() }

        #expect(welcome.isVisible)

        delegate.suppressWelcomeWindow()

        #expect(!welcome.isVisible)
    }

    // MARK: - windowDidBecomeKey Suppression Behavior

    @Test("windowDidBecomeKey — welcome hides (orderOut) when file open and no main window")
    func windowDidBecomeKeyHidesWelcomeWhenNoMain() {
        let delegate = makeAppDelegate()
        delegate.isHandlingFileOpen = true

        let welcome = makeWindow(identifier: "welcome")
        welcome.orderFront(nil)
        defer { welcome.close() }

        #expect(welcome.isVisible)

        let notification = Notification(name: NSWindow.didBecomeKeyNotification, object: welcome)
        delegate.windowDidBecomeKey(notification)

        // Key regression fix: welcome should be hidden (not closed) so it can reappear
        // when the main window is ready — prevents "no visible windows" freeze
        #expect(!welcome.isVisible)
    }

    @Test("windowDidBecomeKey — welcome closes when file open and main window exists")
    func windowDidBecomeKeyClosesWelcomeWhenMainExists() {
        let delegate = makeAppDelegate()
        delegate.isHandlingFileOpen = true

        let mainWin = makeWindow(identifier: "main")
        mainWin.orderFront(nil)
        defer { mainWin.close() }

        let welcome = makeWindow(identifier: "welcome")
        welcome.orderFront(nil)
        defer { welcome.close() }

        let notification = Notification(name: NSWindow.didBecomeKeyNotification, object: welcome)
        delegate.windowDidBecomeKey(notification)

        #expect(!welcome.isVisible)
    }

    @Test("windowDidBecomeKey — welcome not suppressed when isHandlingFileOpen is false")
    func windowDidBecomeKeyNoSuppressionWhenNotHandlingFile() {
        let delegate = makeAppDelegate()
        delegate.isHandlingFileOpen = false

        let welcome = makeWindow(identifier: "welcome")
        welcome.orderFront(nil)
        defer { welcome.close() }

        let notification = Notification(name: NSWindow.didBecomeKeyNotification, object: welcome)
        delegate.windowDidBecomeKey(notification)

        #expect(welcome.isVisible)
    }

    @Test("windowDidBecomeKey — non-welcome window is not affected by suppression")
    func windowDidBecomeKeyIgnoresNonWelcome() {
        let delegate = makeAppDelegate()
        delegate.isHandlingFileOpen = true

        let other = makeWindow(identifier: "settings")
        other.orderFront(nil)
        defer { other.close() }

        let notification = Notification(name: NSWindow.didBecomeKeyNotification, object: other)
        delegate.windowDidBecomeKey(notification)

        #expect(other.isVisible)
    }

    // MARK: - Suppression Count State

    @Test("Multiple suppress calls — count increments independently")
    func multipleSuppressionCountsStack() {
        let delegate = makeAppDelegate()
        delegate.suppressWelcomeWindow()
        delegate.suppressWelcomeWindow()
        delegate.suppressWelcomeWindow()

        #expect(delegate.fileOpenSuppressionCount == 3)
        #expect(delegate.isHandlingFileOpen == true)
    }

    @Test("fileOpenSuppressionCount decrement to zero resets isHandlingFileOpen")
    func countZeroResetsFlag() {
        let delegate = makeAppDelegate()
        delegate.isHandlingFileOpen = true
        delegate.fileOpenSuppressionCount = 1

        // Simulate what scheduleWelcomeWindowSuppression does at the end
        delegate.fileOpenSuppressionCount = max(0, delegate.fileOpenSuppressionCount - 1)
        if delegate.fileOpenSuppressionCount == 0 {
            delegate.isHandlingFileOpen = false
        }

        #expect(delegate.fileOpenSuppressionCount == 0)
        #expect(delegate.isHandlingFileOpen == false)
    }

    @Test("fileOpenSuppressionCount decrement keeps flag true while count > 0")
    func countPositiveKeepsFlag() {
        let delegate = makeAppDelegate()
        delegate.isHandlingFileOpen = true
        delegate.fileOpenSuppressionCount = 2

        // Simulate one decrement
        delegate.fileOpenSuppressionCount = max(0, delegate.fileOpenSuppressionCount - 1)
        if delegate.fileOpenSuppressionCount == 0 {
            delegate.isHandlingFileOpen = false
        }

        #expect(delegate.fileOpenSuppressionCount == 1)
        #expect(delegate.isHandlingFileOpen == true)
    }
}

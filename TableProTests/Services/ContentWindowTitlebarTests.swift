//
//  ContentWindowTitlebarTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

/// The four content windows as the app builds them. Never ordered front and never closed: `close()`
/// on a test window over-releases it.
@MainActor
struct ContentWindowTitlebarTests {
    private struct Built {
        let name: String
        let window: NSWindow
        let separator: NSTitlebarSeparatorStyle
        let owner: AnyObject?
    }

    private var transparentRelease: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private func builtWindows() throws -> [Built] {
        let dataFile = DataFileWindowController(document: DataFileDocument())
        let dataFileWindow = try #require(dataFile.window)
        return [
            Built(name: "main", window: TabWindowController.makeEditorWindow(), separator: .none, owner: nil),
            Built(name: "data file", window: dataFileWindow, separator: .automatic, owner: dataFile),
            Built(name: "compare", window: CompareSyncWindowController.makeWindow(), separator: .automatic, owner: nil),
            Built(
                name: "value viewer",
                window: ValueViewerWindowController.makeWindow(identifier: "titlebar-test", title: "Value") { _ in
                    Color.clear
                },
                separator: .automatic,
                owner: nil
            ),
        ]
    }

    private func tearDown(_ built: [Built]) {
        for entry in built {
            entry.window.delegate = nil
            entry.window.contentViewController = nil
            entry.window.isReleasedWhenClosed = false
        }
    }

    @Test("Every content window shows its backdrop through the titlebar on macOS 26 and later only")
    func transparentFromTheBackdropRelease() throws {
        let built = try builtWindows()
        defer { tearDown(built) }
        for entry in built {
            #expect(entry.window is ContentWindow, "\(entry.name) is not a content window")
            #expect(
                entry.window.titlebarAppearsTransparent == transparentRelease,
                "\(entry.name) titlebar transparent: \(entry.window.titlebarAppearsTransparent)"
            )
        }
    }

    @Test("Each content window keeps the toolbar separator it had")
    func separatorIsUnchanged() throws {
        let built = try builtWindows()
        defer { tearDown(built) }
        for entry in built {
            #expect(entry.window.titlebarSeparatorStyle == entry.separator, "\(entry.name) separator changed")
        }
    }

    @Test(
        "The titlebar stays opaque only in full screen with the toolbar hidden",
        arguments: [
            (isFullScreen: false, toolbarVisible: false, transparent: true),
            (isFullScreen: false, toolbarVisible: true, transparent: true),
            (isFullScreen: true, toolbarVisible: true, transparent: true),
            (isFullScreen: true, toolbarVisible: false, transparent: false),
        ]
    )
    func transparencyFollowsTheSafeArea(state: (isFullScreen: Bool, toolbarVisible: Bool, transparent: Bool)) {
        #expect(
            ContentWindow.titlebarIsTransparent(
                isFullScreen: state.isFullScreen,
                toolbarVisible: state.toolbarVisible
            ) == state.transparent
        )
    }

    @Test(
        "Entering full screen without a toolbar restores the titlebar background, and leaving clears it",
        .enabled(
            if: ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
            ),
            "the titlebar turns transparent from macOS 26"
        )
    )
    func fullScreenWithoutAToolbar() throws {
        let built = try builtWindows()
        defer { tearDown(built) }
        let viewer = try #require(built.first { $0.name == "value viewer" }?.window)
        #expect(viewer.toolbar == nil)

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: viewer)
        #expect(!viewer.titlebarAppearsTransparent)

        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: viewer)
        #expect(viewer.titlebarAppearsTransparent)
    }

    @Test(
        "A full-screen window keeps a transparent titlebar while its toolbar is showing",
        .enabled(
            if: ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
            ),
            "the titlebar turns transparent from macOS 26"
        )
    )
    func fullScreenWithAToolbar() throws {
        let window = CompareSyncWindowController.makeWindow()
        defer { window.toolbar = nil }
        let toolbar = NSToolbar(identifier: "com.TablePro.tests.titlebar.\(UUID().uuidString)")
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        toolbar.isVisible = true
        try #require(toolbar.isVisible)

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(window.titlebarAppearsTransparent)

        toolbar.isVisible = false
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(!window.titlebarAppearsTransparent)
    }
}

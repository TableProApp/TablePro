//
//  WelcomeToolbarTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct WelcomeToolbarTests {
    private func withWelcomeWindow(_ body: (NSWindow) async throws -> Void) async rethrows {
        let window = WelcomeWindowController.makeWelcomeWindow()
        #expect(!window.isReleasedWhenClosed)
        defer {
            window.contentViewController = nil
            window.close()
        }
        try await body(window)
    }

    private func expectFixedAtIconOnly(_ toolbar: NSToolbar?) {
        #expect(toolbar?.displayMode == .iconOnly)
        #expect(toolbar?.allowsUserCustomization == false)
        #expect(toolbar?.autosavesConfiguration == false)
        if #available(macOS 15.0, *) {
            #expect(toolbar?.allowsDisplayModeCustomization == false)
        }
    }

    @Test("The welcome window's own toolbar offers no display mode choice")
    func ownToolbarIsFixedAtIconOnly() async {
        await withWelcomeWindow { window in
            #expect(window.toolbar != nil)
            #expect(window.toolbarStyle == .unified)
            expectFixedAtIconOnly(window.toolbar)
        }
    }

    @Test("A toolbar installed after the window is built is fixed at Icon Only too")
    func laterToolbarIsFixedAtIconOnly() async {
        await withWelcomeWindow { window in
            let toolbar = NSToolbar(identifier: "com.TablePro.tests.welcome.replacement")
            toolbar.displayMode = .iconAndLabel
            toolbar.allowsUserCustomization = true
            toolbar.autosavesConfiguration = true
            if #available(macOS 15.0, *) {
                toolbar.allowsDisplayModeCustomization = true
            }

            window.toolbar = toolbar

            expectFixedAtIconOnly(window.toolbar)
        }
    }

    @Test("The toolbar SwiftUI installs for the list pane offers no display mode choice")
    func bridgedToolbarIsFixedAtIconOnly() async throws {
        guard #available(macOS 14.0, *) else { return }
        try await withWelcomeWindow { window in
            let seed = try #require(window.toolbar)
            let content = NSHostingController(rootView: BridgedToolbarContent())
            content.sizingOptions = []
            content.sceneBridgingOptions = [.toolbars]

            window.contentViewController = content
            var waits = 0
            while window.toolbar === seed, waits < 100 {
                waits += 1
                try await Task.sleep(for: .milliseconds(10))
            }

            let bridged = try #require(window.toolbar)
            #expect(bridged !== seed)
            #expect(bridged.items.contains { $0 is NSSearchToolbarItem })
            expectFixedAtIconOnly(bridged)
        }
    }
}

private struct BridgedToolbarContent: View {
    @State private var searchText = ""

    var body: some View {
        Color.clear
            .searchable(text: $searchText, placement: .toolbar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {} label: {
                        Label("New Connection", systemImage: "plus")
                    }
                    Button {} label: {
                        Label("New Group", systemImage: "folder.badge.plus")
                    }
                }
            }
    }
}

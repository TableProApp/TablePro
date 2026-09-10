//
//  EditorWindowChromeTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@Suite("Editor window chrome")
@MainActor
struct EditorWindowChromeTests {
    /// The real window the app opens, not a stand-in, so removing the chrome call from
    /// `makeEditorWindow` fails here rather than passing against a window the test configured.
    private func withEditorWindow(_ body: (NSWindow) -> Void) {
        let window = TabWindowController.makeEditorWindow()
        window.isReleasedWhenClosed = false
        body(window)
        window.close()
    }

    @Test("The editor window asks for no rule between its toolbar and its content pane")
    func titlebarCarriesNoSeparator() {
        withEditorWindow { window in
            #expect(window.titlebarSeparatorStyle == .none)
        }
    }

    /// `titlebarSeparatorStyle` stopped reaching that rule in macOS 26, so the transparent titlebar
    /// is the part that does the work there, and only there.
    @Test("A transparent titlebar is used only where the separator preference stopped working")
    func transparentTitlebarIsVersionGated() {
        withEditorWindow { window in
            if #available(macOS 26.0, *) {
                #expect(window.titlebarAppearsTransparent)
            } else {
                #expect(!window.titlebarAppearsTransparent)
            }
        }
    }

    /// A full-screen window with no toolbar has a top safe area of zero, so its content reaches the
    /// screen edge and the titlebar that slides down over it has to bring its own background.
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
            TabWindowController.titlebarIsTransparent(
                isFullScreen: state.isFullScreen,
                toolbarVisible: state.toolbarVisible
            ) == state.transparent
        )
    }

    @Test("Entering full screen with the toolbar hidden restores the titlebar background")
    func enteringFullScreenWithoutAToolbarRestoresTheBackground() {
        withEditorWindow { window in
            TabWindowController.applyTitlebarChrome(to: window, isFullScreen: true)

            if #available(macOS 26.0, *) {
                #expect(!window.titlebarAppearsTransparent)
            }

            TabWindowController.applyTitlebarChrome(to: window, isFullScreen: false)
            if #available(macOS 26.0, *) {
                #expect(window.titlebarAppearsTransparent)
            }
        }
    }
}

//
//  EditorWindowChromeTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

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

    /// The window's panes are hosting controllers SwiftUI fills in later than the window appears, and
    /// a loop worked out once never sees them: the editor and the data grid were not Tab stops at
    /// all, and a keyboard-only user could not leave the sidebar.
    @Test("The editor window keeps its key view loop current as panes arrive")
    func keyViewLoopStaysCurrent() {
        withEditorWindow { window in
            #expect(window.autorecalculatesKeyViewLoop)
        }
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

    @Test("The editor window is a content window, so it follows the shared titlebar policy")
    func editorWindowIsAContentWindow() {
        withEditorWindow { window in
            #expect(window is ContentWindow)
        }
    }
}

import AppKit
@testable import TablePro
import Testing

// The app's autosave name is nil in the unit host, so each case passes its own name and removes it.
@MainActor
struct SettingsWindowSizingTests {
    private static let width = SettingsSplitViewController.contentWidth

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: SettingsWindowController.styleMask,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func contentSize(of window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    private func defaultSize(for window: NSWindow) -> NSSize {
        SettingsWindowController.defaultContentSize(on: window.screen ?? NSScreen.main)
    }

    private func withAutosaveName(_ body: (String) -> Void) {
        let name = "TableProTests.SettingsWindow.\(UUID().uuidString)"
        body(name)
        NSWindow.removeFrame(usingName: name)
    }

    @Test("The default is 700 points tall, or less on a short screen, never under the minimum")
    func defaultHeightFitsTheScreen() {
        #expect(SettingsWindowController.defaultContentSize(on: nil) == NSSize(width: Self.width, height: 700))
        let size = SettingsWindowController.defaultContentSize(on: NSScreen.main)
        #expect(size.width == Self.width)
        #expect(size.height <= 700)
        #expect(size.height >= SettingsSplitViewController.minimumContentSize.height)
    }

    @Test("With no saved frame the window opens at the default size")
    func noSavedFrameUsesTheDefault() {
        let window = makeWindow()
        SettingsWindowController.applyFrame(to: window, autosaveName: nil)
        #expect(contentSize(of: window) == defaultSize(for: window))
    }

    @Test("A saved height survives two reconstructions unchanged")
    func savedHeightSurvivesTwoReconstructions() {
        withAutosaveName { name in
            let first = makeWindow()
            SettingsWindowController.applyFrame(to: first, autosaveName: name)
            first.setContentSize(NSSize(width: Self.width, height: 600))
            first.saveFrame(usingName: name)
            first.setFrameAutosaveName("")

            for _ in 0..<2 {
                let next = makeWindow()
                SettingsWindowController.applyFrame(to: next, autosaveName: name)
                #expect(contentSize(of: next) == NSSize(width: Self.width, height: 600))
                next.setFrameAutosaveName("")
            }
        }
    }

    @Test("A frame saved at an older width falls back to the default size")
    func olderWidthFallsBackToTheDefault() {
        withAutosaveName { name in
            let old = makeWindow()
            old.setContentSize(NSSize(width: 768, height: 480))
            old.saveFrame(usingName: name)

            let window = makeWindow()
            SettingsWindowController.applyFrame(to: window, autosaveName: name)
            #expect(contentSize(of: window) == defaultSize(for: window))
            window.setFrameAutosaveName("")
        }
    }

    @Test("A saved frame shorter than the minimum grows to the minimum")
    func shortFrameGrowsToTheMinimum() {
        withAutosaveName { name in
            let old = makeWindow()
            old.setContentSize(NSSize(width: Self.width, height: 300))
            old.saveFrame(usingName: name)

            let window = makeWindow()
            SettingsWindowController.applyFrame(to: window, autosaveName: name)
            #expect(contentSize(of: window) == SettingsSplitViewController.minimumContentSize)
            window.setFrameAutosaveName("")
        }
    }
}

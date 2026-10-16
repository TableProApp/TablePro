import AppKit
import Foundation
@testable import TablePro
import TableProTestSupport
import TableProTheme
import Testing

@MainActor
struct ThemeEditorWindowTests {
    private typealias Fixture = ThemeLibraryTestFixture

    private func makeWindows(_ fixture: Fixture) -> ThemeEditorWindows {
        ThemeEditorWindows(
            catalog: fixture.catalog,
            preview: fixture.preview,
            selection: fixture.selection,
            notificationCenter: fixture.center
        )
    }

    @Test("Opening a theme twice brings its one window forward, titled and proxied by the theme")
    func oneWindowPerTheme() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"), as: "Midnight.json")
        let windows = makeWindows(fixture)

        windows.openEditor(for: "user.aaaa0002")
        let controller = try #require(windows.controller(for: "user.aaaa0002"))
        windows.openEditor(for: "user.aaaa0002")

        #expect(windows.controller(for: "user.aaaa0002") === controller)
        #expect(windows.openThemeIds == ["user.aaaa0002"])
        let window = try #require(controller.window)
        #expect(window.title == "Midnight")
        #expect(window.representedURL?.lastPathComponent == "Midnight.json")
        #expect(window.identifier?.rawValue == ThemeEditorWindowController.windowIdentifier)
        #expect(window.undoManager === controller.model.undoManager)

        Fixture.step(controller.model) { controller.model.rename(to: "Night Owl") }
        #expect(window.title == "Night Owl")

        windows.closeEditor(for: "user.aaaa0002")
        #expect(windows.openThemeIds.isEmpty)
        #expect(!window.isVisible)
        #expect(fixture.preview.ended.contains("user.aaaa0002"))
        #expect(try fixture.onDisk("Midnight.json").name == "Night Owl")
    }

    /// The preview's editor and grid keep undo histories of their own, so while either held focus
    /// Edit > Undo did nothing to the theme.
    @Test("The preview takes no clicks and gives up focus, so Undo reaches the theme")
    func previewNeverHoldsFocus() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"), as: "Midnight.json")
        let windows = makeWindows(fixture)
        windows.openEditor(for: "user.aaaa0002")
        let controller = try #require(windows.controller(for: "user.aaaa0002"))
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        let views = Self.subviews(of: try #require(window.contentView))
        let surface = try #require(views.first { $0 is ThemePreviewSurface })
        #expect(surface.hitTest(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY)) == nil)

        let grid = try #require(views.first { $0 is NSTableView && $0.isInsideThemePreview })
        #expect(window.makeFirstResponder(grid))
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))

        #expect(window.firstResponder === window)
        #expect(window.firstResponder?.undoManager === controller.model.undoManager)
        windows.closeEditor(for: "user.aaaa0002")
    }

    /// AppKit's key view loop reached the preview's editor and grid, and Undo then went to their empty
    /// histories instead of the theme's.
    @Test("Tab and Shift-Tab pass over the preview")
    func tabPassesOverThePreview() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"), as: "Midnight.json")
        let windows = makeWindows(fixture)
        windows.openEditor(for: "user.aaaa0002")
        let controller = try #require(windows.controller(for: "user.aaaa0002"))
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        defer { windows.closeEditor(for: "user.aaaa0002") }

        let fields = Self.subviews(of: try #require(window.contentView))
            .compactMap { $0 as? NSTextField }
            .filter { $0.isEditable && !$0.isInsideThemePreview }
            .sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
        #expect(fields.count == 2)
        let name = try #require(fields.first)
        let author = try #require(fields.last)

        #expect(window.makeFirstResponder(author))
        Self.fieldEditor(of: window)?.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(!Self.isPreviewFocused(in: window))
        #expect(window.firstResponder !== window)

        #expect(window.makeFirstResponder(name))
        Self.fieldEditor(of: window)?.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(!Self.isPreviewFocused(in: window))
        #expect(window.firstResponder !== window)

        window.makeFirstResponder(nil)
        window.selectNextKeyView(nil)
        #expect(!Self.isPreviewFocused(in: window))
    }

    private static func fieldEditor(of window: NSWindow) -> NSTextView? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor
    }

    private static func isPreviewFocused(in window: NSWindow) -> Bool {
        guard let view = window.firstResponder as? NSView else { return false }
        return view.isInsideThemePreview
    }

    /// Quitting closes no window, so the field's text reached no commit.
    @Test("Quitting writes the name still being typed")
    func quitWritesTheTypedName() async throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"), as: "Midnight.json")
        let windows = makeWindows(fixture)
        windows.openEditor(for: "user.aaaa0002")
        let controller = try #require(windows.controller(for: "user.aaaa0002"))
        defer { windows.closeEditor(for: "user.aaaa0002") }

        controller.model.nameText = "Night Owl"
        fixture.center.post(name: NSApplication.willTerminateNotification, object: nil)

        try await waitUntil { (try? fixture.onDisk("Midnight.json").name) == "Night Owl" }
    }

    @Test("Quitting over a refused name is cancelled, with the window kept and the reason shown")
    func quitOverARefusedNameIsCancelled() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0001", "Paper", appearance: .light))
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"), as: "Midnight.json")
        let windows = makeWindows(fixture)
        windows.openEditor(for: "user.aaaa0002")
        let controller = try #require(windows.controller(for: "user.aaaa0002"))
        defer { windows.closeEditor(for: "user.aaaa0002") }

        controller.model.nameText = "Paper"

        #expect(!windows.prepareToTerminate())
        #expect(windows.openThemeIds == ["user.aaaa0002"])
        #expect(controller.model.nameError == "A theme named “Paper” already exists.")
    }

    @Test("Quitting over a failed save asks first, and only a confirmed quit goes ahead")
    func quitOverAFailedSaveAsks() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"), as: "Midnight.json")
        var answer = false
        var asked: [String] = []
        let windows = ThemeEditorWindows(
            catalog: fixture.catalog,
            preview: fixture.preview,
            selection: fixture.selection,
            notificationCenter: fixture.center,
            confirmQuitWithoutSaving: { name, _ in
                asked.append(name)
                return answer
            }
        )
        windows.openEditor(for: "user.aaaa0002")
        let controller = try #require(windows.controller(for: "user.aaaa0002"))
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.themes.path)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.themes.path)
            windows.closeEditor(for: "user.aaaa0002")
        }

        controller.model.nameText = "Night Owl"

        #expect(!windows.prepareToTerminate())
        answer = true
        #expect(windows.prepareToTerminate())
        #expect(asked == ["Night Owl", "Night Owl"])
    }

    @Test("Quitting with a clean editor saves what was typed and lets the quit go ahead")
    func quitWithACleanEditorSaves() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"), as: "Midnight.json")
        let windows = makeWindows(fixture)
        windows.openEditor(for: "user.aaaa0002")
        let controller = try #require(windows.controller(for: "user.aaaa0002"))
        defer { windows.closeEditor(for: "user.aaaa0002") }

        controller.model.nameText = "Night Owl"

        #expect(windows.prepareToTerminate())
        #expect(try fixture.onDisk("Midnight.json").name == "Night Owl")
    }

    /// The close button takes no focus, so the rename was still pending, refused, and dropped as the
    /// window closed in the same event.
    @Test("Closing with a taken name keeps the window open with the reason")
    func closeWithATakenNameKeepsTheWindow() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0001", "Paper", appearance: .light))
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"), as: "Midnight.json")
        let windows = makeWindows(fixture)
        windows.openEditor(for: "user.aaaa0002")
        let controller = try #require(windows.controller(for: "user.aaaa0002"))
        let window = try #require(controller.window)

        controller.model.nameText = "Paper"
        window.performClose(nil)
        #expect(window.isVisible)
        #expect(windows.openThemeIds == ["user.aaaa0002"])
        #expect(controller.model.nameError == "A theme named “Paper” already exists.")

        controller.model.nameText = "Night Owl"
        window.performClose(nil)
        #expect(windows.openThemeIds.isEmpty)
        #expect(try fixture.onDisk("Midnight.json").name == "Night Owl")
    }

    private static func subviews(of root: NSView) -> [NSView] {
        var found: [NSView] = []
        var pending = [root]
        while let view = pending.popLast() {
            found.append(view)
            pending.append(contentsOf: view.subviews)
        }
        return found
    }

    @Test("Closing with the close button saves and forgets the window")
    func closeButtonSavesAndForgets() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"), as: "Midnight.json")
        let windows = makeWindows(fixture)
        windows.openEditor(for: "user.aaaa0002")
        let controller = try #require(windows.controller(for: "user.aaaa0002"))
        let window = try #require(controller.window)

        Fixture.step(controller.model) { controller.model.setColor(Fixture.pink, for: .editorText) }
        window.performClose(nil)

        #expect(windows.openThemeIds.isEmpty)
        #expect(try fixture.onDisk("Midnight.json").overrides[.editorText] == Fixture.pink)
    }

    @Test("A built-in theme opens read-only, and Duplicate hands over to an editor for the copy")
    func duplicateFromABuiltIn() throws {
        let fixture = try Fixture()
        let windows = makeWindows(fixture)

        windows.openEditor(for: BuiltInThemes.defaultDarkId)
        let readOnly = try #require(windows.controller(for: BuiltInThemes.defaultDarkId))
        #expect(readOnly.model.isReadOnly)
        #expect(readOnly.window?.representedURL == nil)

        windows.duplicate(from: readOnly)

        #expect(windows.controller(for: BuiltInThemes.defaultDarkId) == nil)
        let copyId = try #require(windows.openThemeIds.first)
        #expect(copyId != BuiltInThemes.defaultDarkId)
        let copy = try #require(windows.controller(for: copyId))
        #expect(!copy.model.isReadOnly)
        #expect(copy.window?.title == "Default Dark Copy")
        windows.closeEditor(for: copyId)
    }

    @Test("Keep Theme after a deletion keeps the window under the theme's new id")
    func keptThemeIsRekeyed() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"), as: "Midnight.json")
        let windows = makeWindows(fixture)
        windows.openEditor(for: "user.aaaa0002")
        let controller = try #require(windows.controller(for: "user.aaaa0002"))

        try FileManager.default.removeItem(at: fixture.themes.appendingPathComponent("Midnight.json"))
        fixture.catalog.reloadSynchronously()
        controller.model.keepAsNewTheme()

        let newId = controller.model.draft.id
        #expect(windows.controller(for: "user.aaaa0002") == nil)
        #expect(windows.controller(for: newId) === controller)
        #expect(controller.window?.representedURL?.lastPathComponent == "\(newId).json")
        windows.closeEditor(for: newId)
    }
}

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
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

    // The preview's editor and grid have undo histories of their own, so while either held focus Edit > Undo missed the theme.
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

    // AppKit's key view loop reached the preview's editor and grid, and Undo then went to their empty histories.
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

    // Quitting closes no window, so the field's text reached no commit.
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

    // The close button takes no focus, so the pending rename was refused and dropped as the window closed in the same event.
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

    // MARK: - Preview grid

    @Test("The preview grid has a column for every value color, both booleans and a NULL")
    func previewSampleShowsEveryValueColor() throws {
        let rows = ThemePreviewGridSample.tableRows
        let tones = Set(rows.columnTypes.map { DataGridValueTone.base(of: $0, declaresEnumLabels: false) })
        #expect(tones == [.plain, .string, .number, .dateTime, .binary, .json, .uuid, .enumeration])
        #expect(ThemePreviewGridSample.configuration.colorsValuesByType)
        #expect(ThemePreviewGridSample.configuration.overridesValueColorSetting)

        let boolean = try #require(rows.columnTypes.firstIndex { $0.isBooleanType })
        #expect(Set(rows.rows.map { $0.values[boolean] }) == [.text("true"), .text("false")])
        #expect(rows.rows.contains { $0.values.contains(.null) })

        let marked = [
            ThemePreviewGridSample.selectedRow,
            ThemePreviewGridSample.modifiedRow,
            ThemePreviewGridSample.deletedRow,
            ThemePreviewGridSample.insertedRow,
        ]
        #expect(Set(marked).count == marked.count)
        #expect(marked.allSatisfy { rows.rows.indices.contains($0) })
        let modified = rows.rows[ThemePreviewGridSample.modifiedRow].values[ThemePreviewGridSample.modifiedColumn]
        #expect(modified != .null)
    }

    // The preview shows the theme being edited, so it never waits for the grid setting to be turned on.
    @Test("The preview grid draws the theme's value colors while Color values by type is off")
    func previewColorsValuesWithTheSettingOff() throws {
        let owner = GridTestOwner(ThemePreviewGridSample.tableRows)
        let model = DataGridModel(
            configuration: ThemePreviewGridSample.configuration,
            themeScope: .fixed(try ThemeTestFixture.theme(.light, [
                .gridText: "#111111",
                .gridString: "#AA1100",
                .gridNumber: "#0044AA",
            ]))
        )
        model.dataSource = owner
        model.reloadRows()
        let presenter = DataGridCellPresenter(model: model, valueColors: ValueColorSettings(colorsValuesByType: false))
        presenter.refreshColumnPresentations()
        let aqua = try #require(NSAppearance(named: .aqua))
        let pass = try #require(presenter.makePass(in: aqua))
        let row = try #require(model.row(at: 0))

        let colors = try ["id", "name"].map { name in
            let index = try #require(ThemePreviewGridSample.columns.firstIndex { $0.name == name })
            let column = try #require(model.columns.column(at: index))
            let appearance = try #require(presenter.appearance(
                of: row,
                displayRow: 0,
                column: column,
                visualState: .empty,
                pass: pass,
                onEmphasizedSelection: false
            ))
            return ThemeTestFixture.hex(appearance.textColor)
        }
        withExtendedLifetime(owner) {}

        #expect(colors == ["#0044AA", "#AA1100"])
    }

    @Test("The Values section says where to turn value colors on, only while Color values by type is off")
    func valuesNoteFollowsTheSetting() {
        for section in ThemeSlotSection.allCases {
            #expect(ThemeValueColorsNote.message(for: section, colorsValuesByType: true) == nil, "\(section)")
            let off = ThemeValueColorsNote.message(for: section, colorsValuesByType: false)
            #expect((off != nil) == (section == .values), "\(section)")
        }
        let note = ThemeValueColorsNote.message(for: .values, colorsValuesByType: false)
        #expect(note?.hasSuffix("Settings > Data.") == true)
    }

    // A UUID is wider than any column the window has room for, so it alone ends in an ellipsis.
    @Test("Every sample value but the UUID fits its column at the default grid font")
    func previewSampleValuesFitTheirColumns() {
        let font = DataGridFontCache(from: .default).regular
        let null = DataGridSettings.default.nullDisplay
        let rows = ThemePreviewGridSample.tableRows
        for (index, column) in ThemePreviewGridSample.columns.enumerated() where !column.type.isUUIDType {
            for row in rows.rows {
                let shown = CellDisplayFormatter.format(row.values[index], columnType: column.type) ?? null
                let width = (shown as NSString).size(withAttributes: [.font: font]).width
                    + 2 * DataGridMetrics.cellHorizontalInset
                #expect(width <= column.width, "\(column.name) \(shown): \(width)")
            }
        }
    }

    // The preview takes no scroll events, so a column past the window's edge never shows.
    @Test("The preview grid shows every sample column inside the editor window")
    func previewGridFitsTheWindow() async throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"), as: "Midnight.json")
        let windows = makeWindows(fixture)
        windows.openEditor(for: "user.aaaa0002")
        let controller = try #require(windows.controller(for: "user.aaaa0002"))
        defer { windows.closeEditor(for: "user.aaaa0002") }
        let content = try #require(controller.window?.contentView)

        try await waitUntil {
            content.layoutSubtreeIfNeeded()
            return Self.previewGrid(in: content) != nil
        }
        let grid = try #require(Self.previewGrid(in: content))
        let clip = try #require(grid.enclosingScrollView?.contentView)
        #expect(grid.rect(ofColumn: grid.numberOfColumns - 1).maxX <= clip.bounds.width)
    }

    // The main pane holds the row numbers and every column; the frozen pane only the row numbers.
    private static func previewGrid(in root: NSView) -> NSTableView? {
        let columnCount = ThemePreviewGridSample.columns.count + 1
        return subviews(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.isInsideThemePreview && $0.numberOfColumns == columnCount }
    }
}

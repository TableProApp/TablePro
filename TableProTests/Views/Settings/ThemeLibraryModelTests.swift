import AppKit
import Foundation
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct ThemeLibraryModelTests {
    private typealias Fixture = ThemeLibraryTestFixture

    @Test("The list holds the built-ins, the user's themes and the refused files apart")
    func listSections() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0001", "Paper", appearance: .light))
        try Data("{".utf8).write(to: fixture.themes.appendingPathComponent("Broken.json"))
        fixture.catalog.reloadSynchronously()
        let library = fixture.makeLibrary()

        #expect(library.builtInThemes.map(\.id) == [BuiltInThemes.defaultLightId, BuiltInThemes.defaultDarkId])
        #expect(library.customThemes.map(\.id) == ["user.aaaa0001"])
        #expect(library.notLoaded.map(\.fileName) == ["Broken.json"])
        #expect(library.canTrash(.theme("user.aaaa0001")))
        #expect(!library.canTrash(.theme(BuiltInThemes.defaultDarkId)))
        let broken = try #require(library.notLoaded.first)
        #expect(library.canTrash(.notLoaded(path: broken.path)))
    }

    @Test("Duplicate writes a copy with a new id and its own name, and New Theme Based On opens it")
    func duplicateAndCreate() throws {
        let fixture = try Fixture()
        let library = fixture.makeLibrary()

        let copy = try #require(library.duplicate(BuiltInThemes.defaultDarkId, undoManager: nil))
        #expect(copy.id != BuiltInThemes.defaultDarkId)
        #expect(copy.isEditable)
        #expect(copy.name == "Default Dark Copy")
        #expect(fixture.editors.opened.isEmpty)
        #expect(try fixture.fileNames() == ["\(copy.id).json"])

        let created = try #require(library.createTheme(basedOn: BuiltInThemes.defaultDarkId, undoManager: nil))
        #expect(created.name == "Default Dark Copy 2")
        #expect(fixture.editors.opened == [created.id])
    }

    /// A copy of a default has no syntax colors of its own, so it keeps Xcode's Increase Contrast
    /// palette instead of freezing the standard one into the file.
    @Test("A duplicate of a default keeps the adaptive syntax palette")
    func duplicateOfDefaultKeepsAdaptiveSyntax() throws {
        let fixture = try Fixture()
        let library = fixture.makeLibrary()

        let copy = try #require(library.duplicate(BuiltInThemes.defaultLightId, undoManager: nil))
        let stored = try fixture.onDisk("\(copy.id).json")
        #expect(stored.overrides.isEmpty)
        #expect(stored.value(for: .syntaxKeyword, highContrast: true) == .defaultSyntax(.syntaxKeyword))

        // A high-contrast appearance cannot be made in the test host, so the check is that the copy
        // draws the adaptive color object itself, which switches palettes at draw time.
        let adaptive = try #require(BuiltInThemes.adaptiveSyntaxColor(.syntaxKeyword, appearance: .light))
        #expect(stored.color(for: .syntaxKeyword) === adaptive)
    }

    @Test("Move to Trash releases the slot that held the theme, and Undo puts both back")
    func trashAndUndo() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"))
        fixture.selection.themeSelection.preferredDarkThemeId = "user.aaaa0002"
        let library = fixture.makeLibrary()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        let confirmation = try #require(library.trashConfirmation(for: .theme("user.aaaa0002")))
        #expect(confirmation.title == "Delete “Midnight”?")
        #expect(confirmation.message == "The file moves to the Trash. Dark windows switch to Default Dark.")

        undoManager.beginUndoGrouping()
        let trashed = library.moveToTrash(.theme("user.aaaa0002"), undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(trashed)
        #expect(try fixture.fileNames().isEmpty)
        #expect(fixture.catalog.theme(id: "user.aaaa0002") == nil)
        #expect(fixture.selection.themeSelection.preferredDarkThemeId == BuiltInThemes.defaultDarkId)
        #expect(fixture.editors.closed == ["user.aaaa0002"])
        #expect(undoManager.undoActionName == "Move to Trash")

        undoManager.undo()
        #expect(try fixture.fileNames() == ["user.aaaa0002.json"])
        #expect(fixture.catalog.theme(id: "user.aaaa0002")?.name == "Midnight")
        #expect(fixture.selection.themeSelection.preferredDarkThemeId == "user.aaaa0002")

        undoManager.redo()
        #expect(try fixture.fileNames().isEmpty)
        #expect(fixture.selection.themeSelection.preferredDarkThemeId == BuiltInThemes.defaultDarkId)
    }

    @Test("A theme nothing uses moves to the Trash without asking")
    func unusedThemeNeedsNoConfirmation() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0003", "Spare"))
        let library = fixture.makeLibrary()

        #expect(library.trashConfirmation(for: .theme("user.aaaa0003")) == nil)
        #expect(library.trashConfirmation(for: .theme(BuiltInThemes.defaultDarkId)) == nil)
    }

    @Test("Undo of a trash leaves a slot the user has chosen since alone")
    func undoDoesNotOverrideANewerChoice() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"))
        try fixture.install(Fixture.theme("user.aaaa0004", "Dusk"))
        fixture.selection.themeSelection.preferredDarkThemeId = "user.aaaa0002"
        let library = fixture.makeLibrary()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        library.moveToTrash(.theme("user.aaaa0002"), undoManager: undoManager)
        undoManager.endUndoGrouping()
        library.use("user.aaaa0004", for: .dark)
        undoManager.undo()

        #expect(fixture.catalog.theme(id: "user.aaaa0002") != nil)
        #expect(fixture.selection.themeSelection.preferredDarkThemeId == "user.aaaa0004")
    }

    @Test("A file that did not load moves to the Trash and comes back on Undo")
    func trashNotLoadedFile() throws {
        let fixture = try Fixture()
        try Data("{ \"schema\": 3".utf8).write(to: fixture.themes.appendingPathComponent("Broken.json"))
        fixture.catalog.reloadSynchronously()
        let library = fixture.makeLibrary()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let record = try #require(library.notLoaded.first)
        let broken = URL(fileURLWithPath: record.path)
        let item = ThemeLibraryItem.notLoaded(path: record.path)

        #expect(library.trashConfirmation(for: item) == nil)
        undoManager.beginUndoGrouping()
        #expect(library.moveToTrash(item, undoManager: undoManager))
        undoManager.endUndoGrouping()
        #expect(library.notLoaded.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: broken.path))

        undoManager.undo()
        #expect(library.notLoaded.map(\.fileName) == ["Broken.json"])
    }

    @Test("Importing several files imports each good one and reports the rest in one alert")
    func importSeveralFilesWithMixedResults() throws {
        let fixture = try Fixture()
        let library = fixture.makeLibrary()
        let first = try fixture.writeIncoming(
            "Ocean.json",
            contents: ThemeFileFormat.encode(Fixture.theme("user.11111111", "Ocean"))
        )
        let second = try fixture.writeIncoming(
            "Paper.json",
            contents: ThemeFileFormat.encode(Fixture.theme("user.22222222", "Paper", appearance: .light))
        )
        let broken = try fixture.writeIncoming("Monokai.json", contents: Data("not json".utf8))

        let report = library.importThemes(from: [first, broken, second], undoManager: nil)

        #expect(report.imported.map(\.name) == ["Ocean", "Paper"])
        #expect(report.imported.allSatisfy { $0.id != "user.11111111" && $0.id != "user.22222222" })
        #expect(report.failures.map(\.fileName) == ["Monokai.json"])
        let alert = try #require(library.alert)
        #expect(alert.title == "Imported 2 themes.")
        #expect(alert.message.hasPrefix("Monokai.json could not be read: "))
        #expect(library.customThemes.map(\.name) == ["Ocean", "Paper"])
    }

    @Test("A single file that fails names itself in the alert title")
    func singleFailedImport() throws {
        let fixture = try Fixture()
        let library = fixture.makeLibrary()
        let broken = try fixture.writeIncoming("Monokai.json", contents: Data("[]".utf8))

        let report = library.importThemes(from: [broken], undoManager: nil)

        #expect(report.imported.isEmpty)
        #expect(library.alert?.title == "Couldn't Import “Monokai.json”")
        #expect(library.alert?.message == ThemeLoadError.notATheme.localizedDescription)
    }

    @Test("A clean import raises no alert")
    func cleanImportHasNoAlert() throws {
        let fixture = try Fixture()
        let library = fixture.makeLibrary()
        let file = try fixture.writeIncoming(
            "Ocean.json",
            contents: ThemeFileFormat.encode(Fixture.theme("user.11111111", "Ocean"))
        )

        let report = library.importThemes(from: [file], undoManager: nil)

        #expect(report.imported.count == 1)
        #expect(library.alert == nil)
    }

    @Test("Export hands out the theme's file contents, and a drag writes a named copy outside the Themes folder")
    func exportAndDrag() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Mid/Night", overrides: [.editorBackground: Fixture.midnightBackground]))
        let library = fixture.makeLibrary()

        let document = try #require(library.exportDocument(for: "user.aaaa0002"))
        #expect(try ThemeFileFormat.decode(document.data) == fixture.catalog.theme(id: "user.aaaa0002"))
        #expect(ThemeLibraryModel.exportFileName(for: try #require(fixture.catalog.theme(id: "user.aaaa0002"))) == "Mid-Night")

        let dragged = try library.dragExportURL(for: "user.aaaa0002")
        #expect(dragged.lastPathComponent == "Mid-Night.json")
        #expect(dragged.path.hasPrefix(fixture.drags.path))
        #expect(try ThemeFileFormat.decode(Data(contentsOf: dragged)).name == "Mid/Night")

        let builtIn = try library.dragExportURL(for: BuiltInThemes.defaultDarkId)
        #expect(try ThemeFileFormat.decode(Data(contentsOf: builtIn)).id == BuiltInThemes.defaultDarkId)
    }

    @Test("A row dragged back onto the list is not imported again")
    func dropOfOwnDragIsIgnored() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"))
        let library = fixture.makeLibrary()
        let dragged = try library.dragExportURL(for: "user.aaaa0002")

        let report = library.importThemes(from: [dragged], undoManager: nil)

        #expect(report.imported.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(library.customThemes.count == 1)
    }

    @Test("A rename to another theme's name is refused with the reason and changes nothing")
    func renameCollision() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0001", "Paper", appearance: .light))
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"))
        let library = fixture.makeLibrary()

        #expect(library.rename("user.aaaa0002", to: "  paper ", undoManager: nil) == .rejected("A theme named “paper” already exists."))
        #expect(try fixture.onDisk("user.aaaa0002.json").name == "Midnight")
        #expect(library.rename("user.aaaa0002", to: "   ", undoManager: nil) == .unchanged)
        #expect(library.rename("user.aaaa0002", to: "Midnight", undoManager: nil) == .unchanged)
        #expect(library.rename("user.aaaa0002", to: String(repeating: "x", count: 101), undoManager: nil) == .rejected(ThemeLoadError.invalidName.localizedDescription))

        #expect(library.rename("user.aaaa0002", to: "Night Owl", undoManager: nil) == .renamed("Night Owl"))
        #expect(try fixture.onDisk("user.aaaa0002.json").name == "Night Owl")
    }

    @Test("A rename, a duplicate and an import are undone the way Finder undoes them")
    func listActionsAreUndoable() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"))
        let library = fixture.makeLibrary()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        func step<Result>(_ action: () -> Result) -> Result {
            undoManager.beginUndoGrouping()
            defer { undoManager.endUndoGrouping() }
            return action()
        }

        #expect(step { library.rename("user.aaaa0002", to: "Night Owl", undoManager: undoManager) } == .renamed("Night Owl"))
        #expect(undoManager.undoActionName == "Rename")
        undoManager.undo()
        #expect(try fixture.onDisk("user.aaaa0002.json").name == "Midnight")
        undoManager.redo()
        #expect(try fixture.onDisk("user.aaaa0002.json").name == "Night Owl")

        let copy = try #require(step { library.duplicate("user.aaaa0002", undoManager: undoManager) })
        #expect(undoManager.undoActionName == "Duplicate")
        undoManager.undo()
        #expect(fixture.catalog.theme(id: copy.id) == nil)
        #expect(try fixture.fileNames() == ["user.aaaa0002.json"])
        undoManager.redo()
        #expect(fixture.catalog.theme(id: copy.id)?.name == "Night Owl Copy")

        let file = try fixture.writeIncoming(
            "Ocean.json",
            contents: ThemeFileFormat.encode(Fixture.theme("user.11111111", "Ocean"))
        )
        let report = step { library.importThemes(from: [file], undoManager: undoManager) }
        let imported = try #require(report.imported.first)
        #expect(undoManager.undoActionName == "Import")
        undoManager.undo()
        #expect(fixture.catalog.theme(id: imported.id) == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A rename of a theme open in an editor goes through that editor and is saved at once")
    func renameThroughOpenEditor() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"))
        let editor = try fixture.makeEditor(for: "user.aaaa0002")
        fixture.editors.models["user.aaaa0002"] = editor
        let library = fixture.makeLibrary()

        let outcome = Fixture.step(editor) { library.rename("user.aaaa0002", to: "Night Owl", undoManager: nil) }
        #expect(outcome == .renamed("Night Owl"))
        #expect(editor.draft.name == "Night Owl")
        #expect(editor.undoManager.undoActionName == "Rename")
        #expect(try fixture.onDisk("user.aaaa0002.json").name == "Night Owl")
        #expect(editor.alert == nil)
    }

    /// The list shows the second of two "Ocean" themes as "Ocean 2". The rename field started from that
    /// shown name, and committing it untouched reported a rename and left an Undo step that did nothing.
    @Test("Renaming the second of two same-named themes starts from its stored name, with or without its editor")
    func renameOfADisambiguatedTheme() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0001", "Ocean"))
        try fixture.install(Fixture.theme("user.aaaa0002", "Ocean"))
        let shown = try #require(fixture.catalog.themes.first { $0.name == "Ocean 2" })
        let fileName = "\(shown.id).json"
        let library = fixture.makeLibrary()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        let seed = try #require(library.nameForRenaming(shown.id))
        #expect(seed == "Ocean")
        #expect(library.rename(shown.id, to: seed, undoManager: undoManager) == .unchanged)
        #expect(!undoManager.canUndo)
        #expect(try fixture.onDisk(fileName).name == "Ocean")

        let editor = try fixture.makeEditor(for: shown.id)
        fixture.editors.models[shown.id] = editor
        #expect(editor.nameText == "Ocean")
        #expect(library.rename(shown.id, to: seed, undoManager: undoManager) == .unchanged)
        #expect(!undoManager.canUndo)
        #expect(!editor.undoManager.canUndo)
        #expect(try fixture.onDisk(fileName).name == "Ocean")
        editor.close()
    }

    /// Typed on purpose, the shown name becomes the file's name. It used to be a silent no-op without
    /// an editor open and a write with one.
    @Test("Typing the shown name renames the file the same way with or without its editor", arguments: [false, true])
    func typedShownNameRenamesTheFile(isEditorOpen: Bool) throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0001", "Ocean"))
        try fixture.install(Fixture.theme("user.aaaa0002", "Ocean"))
        let shown = try #require(fixture.catalog.themes.first { $0.name == "Ocean 2" })
        let library = fixture.makeLibrary()
        let editor = try isEditorOpen ? fixture.makeEditor(for: shown.id) : nil
        fixture.editors.models[shown.id] = editor
        defer { editor?.close() }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        #expect(library.rename(shown.id, to: "Ocean 2", undoManager: undoManager) == .renamed("Ocean 2"))
        #expect(try fixture.onDisk("\(shown.id).json").name == "Ocean 2")
        #expect(undoManager.undoActionName == "Rename")
    }

    @Test("Use for an appearance offers only the slot the theme fits and does not already hold")
    func useForAppearance() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"))
        let library = fixture.makeLibrary()
        let midnight = try #require(fixture.catalog.theme(id: "user.aaaa0002"))

        #expect(library.availableSlot(for: midnight) == .dark)
        library.use(midnight.id, for: .dark)
        #expect(fixture.selection.themeSelection.preferredDarkThemeId == midnight.id)
        #expect(library.availableSlot(for: midnight) == nil)
        #expect(library.availableSlot(for: BuiltInThemes.light) == nil)
    }

    @Test("Releasing and reclaiming a theme touch only the slots that held it")
    func releaseAndReclaim() {
        let settings = AppearanceSettings(preferredLightThemeId: "user.aaaa0001", preferredDarkThemeId: "user.aaaa0002")

        let released = settings.releasing(themeId: "user.aaaa0002")
        #expect(released.preferredLightThemeId == "user.aaaa0001")
        #expect(released.preferredDarkThemeId == BuiltInThemes.defaultDarkId)
        #expect(settings.releasing(themeId: "user.other") == settings)
        #expect(released.reclaiming(themeId: "user.aaaa0002", from: settings) == settings)
    }
}

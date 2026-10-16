import AppKit
import Foundation
@testable import TablePro
import TableProTestSupport
import TableProTheme
import Testing

@MainActor
struct ThemeEditorModelTests {
    private typealias Fixture = ThemeLibraryTestFixture

    private static let midnightId = "user.aaaa0002"

    private func midnight(in fixture: Fixture) throws {
        try fixture.install(
            Fixture.theme(Self.midnightId, "Midnight", overrides: [.editorBackground: Fixture.midnightBackground]),
            as: "Midnight.json"
        )
    }

    private func onDisk(_ fixture: Fixture) throws -> ThemeDefinition {
        try fixture.onDisk("Midnight.json")
    }

    // MARK: - Undo

    @Test("Every tick of one well drag is one undo step")
    func wellDragIsOneUndoStep() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId)

        for red in [0x10, 0x20, 0x30, 0x40] as [UInt8] {
            Fixture.step(editor) { editor.setColor(ThemeColor(red: red, green: 0x10, blue: 0x10), for: .editorText) }
        }
        #expect(editor.draft.overrides[.editorText] == ThemeColor(red: 0x40, green: 0x10, blue: 0x10))
        #expect(editor.undoManager.undoActionName == "Color Change")

        editor.undoManager.undo()
        #expect(editor.draft.overrides[.editorText] == nil)
        #expect(!editor.undoManager.canUndo)

        editor.undoManager.redo()
        #expect(editor.draft.overrides[.editorText] == ThemeColor(red: 0x40, green: 0x10, blue: 0x10))
        editor.close()
    }

    @Test("A drag that settled and was saved is its own step, and another slot starts a new one")
    func settledDragStartsANewStep() async throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let clock = ManualClock()
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: clock)

        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }
        await clock.waitUntilSleeping()
        clock.advance(by: ThemeEditorModel.defaultSaveDelay)
        try await waitUntil { (try? self.onDisk(fixture).overrides[.editorText]) == Fixture.pink }

        Fixture.step(editor) { editor.setColor(Fixture.green, for: .editorText) }
        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .syntaxKeyword) }

        editor.undoManager.undo()
        #expect(editor.draft.overrides[.syntaxKeyword] == nil)
        #expect(editor.draft.overrides[.editorText] == Fixture.green)
        editor.undoManager.undo()
        #expect(editor.draft.overrides[.editorText] == Fixture.pink)
        editor.undoManager.undo()
        #expect(editor.draft.overrides[.editorText] == nil)
        editor.close()
    }

    /// A well hands back the color it shows. Storing that echo would freeze a system color into the
    /// file, and the slot would stop following Accent and Increase Contrast.
    @Test("The system color a well shows for an unset slot is not stored when echoed back")
    func echoOfTheShownColorIsIgnored() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId)
        let shown = ThemeSlotPresentation.displayColor(for: .gridBackground, in: editor.draft)

        Fixture.step(editor) { editor.setColor(shown, for: .gridBackground) }

        #expect(!editor.draft.hasExplicitColor(.gridBackground))
        #expect(!editor.undoManager.canUndo)
        #expect(fixture.preview.drafts.isEmpty)
        editor.close()
    }

    @Test("A slot without an opacity control stores an opaque color")
    func opaqueSlotDropsAlpha() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId)
        let translucent = ThemeColor(red: 0xFF, green: 0x79, blue: 0xC6, alpha: 0x80)

        Fixture.step(editor) { editor.setColor(translucent, for: .editorText) }
        Fixture.step(editor) { editor.setColor(translucent, for: .editorSelection) }

        #expect(editor.draft.overrides[.editorText] == translucent.opaque)
        #expect(editor.draft.overrides[.editorSelection] == translucent)
        editor.close()
    }

    @Test("Use System Color removes the slot and is undone by name")
    func resetIsUndoable() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId)

        Fixture.step(editor) { editor.reset(.editorBackground) }
        #expect(!editor.draft.hasExplicitColor(.editorBackground))
        #expect(editor.undoManager.undoActionName == "Use System Color")

        editor.undoManager.undo()
        #expect(editor.draft.overrides[.editorBackground] == Fixture.midnightBackground)
        editor.close()
    }

    @Test("Revert Changes goes back to the theme as it opened, and is undoable")
    func revertAndUndoRevert() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId)
        let opened = editor.draft

        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }
        Fixture.step(editor) { editor.setAppearance(.light) }
        #expect(editor.hasChangesSinceOpening)

        Fixture.step(editor) { editor.revert() }
        #expect(editor.draft == opened)
        #expect(!editor.hasChangesSinceOpening)

        editor.undoManager.undo()
        #expect(editor.draft.appearance == .light)
        #expect(editor.draft.overrides[.editorText] == Fixture.pink)
        editor.close()
    }

    // MARK: - Names

    @Test("A taken name stays in the field with the reason, and the theme keeps its name")
    func takenNameIsShownInline() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        try fixture.install(Fixture.theme("user.aaaa0001", "Paper", appearance: .light))
        let editor = try fixture.makeEditor(for: Self.midnightId)

        editor.nameText = "paper"
        let outcome = Fixture.step(editor) { editor.commitName() }

        #expect(outcome == .rejected("A theme named “paper” already exists."))
        #expect(editor.nameError == "A theme named “paper” already exists.")
        #expect(editor.nameText == "paper")
        #expect(editor.draft.name == "Midnight")
        #expect(!editor.undoManager.canUndo)

        editor.nameText = "Night Owl"
        #expect(Fixture.step(editor) { editor.commitName() } == .renamed("Night Owl"))
        #expect(editor.nameError == nil)
        #expect(editor.undoManager.undoActionName == "Rename")
        editor.close()
    }

    /// Name and Author commit when focus leaves them, and a well click takes no focus, so every
    /// commit used to write the old name and author back over the text being typed.
    @Test("A color, a reset, an appearance or Revert while Name and Author are being typed keeps the text")
    func editsKeepTheTextBeingTyped() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: ManualClock())

        editor.nameText = "Night Owl"
        editor.authorText = "Ada"
        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }
        #expect(editor.nameText == "Night Owl")
        #expect(editor.authorText == "Ada")
        Fixture.step(editor) { editor.reset(.editorBackground) }
        Fixture.step(editor) { editor.setAppearance(.light) }
        Fixture.step(editor) { editor.revert() }
        #expect(editor.nameText == "Night Owl")
        #expect(editor.authorText == "Ada")
        #expect(editor.draft.name == "Midnight")

        #expect(Fixture.step(editor) { editor.commitName() } == .renamed("Night Owl"))
        #expect(Fixture.step(editor) { editor.commitAuthor() })
        #expect(editor.draft.name == "Night Owl")
        #expect(editor.draft.author == "Ada")
        editor.close()
    }

    @Test("A refused name keeps its text and reason through a color change")
    func refusedNameSurvivesAnEdit() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        try fixture.install(Fixture.theme("user.aaaa0001", "Paper", appearance: .light))
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: ManualClock())

        editor.nameText = "Paper"
        Fixture.step(editor) { editor.commitName() }
        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }

        #expect(editor.nameText == "Paper")
        #expect(editor.nameError == "A theme named “Paper” already exists.")
        editor.close()
    }

    @Test("Closing with a refused name or author keeps the window, and closes once it is fixed")
    func refusedFieldKeepsTheWindowOpen() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        try fixture.install(Fixture.theme("user.aaaa0001", "Paper", appearance: .light))
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: ManualClock())
        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }

        editor.nameText = "Paper"
        #expect(editor.prepareToClose() == .keepEditing)
        #expect(editor.nameText == "Paper")
        #expect(editor.nameError == "A theme named “Paper” already exists.")

        editor.nameText = "Night Owl"
        editor.authorText = "Ada\nLovelace"
        #expect(editor.prepareToClose() == .keepEditing)
        #expect(editor.authorError == ThemeLoadError.invalidAuthor.localizedDescription)
        #expect(editor.draft.name == "Night Owl")

        editor.authorText = "Ada"
        #expect(editor.prepareToClose() == .close)
        editor.close()
        let saved = try onDisk(fixture)
        #expect(saved.name == "Night Owl")
        #expect(saved.author == "Ada")
        #expect(saved.overrides[.editorText] == Fixture.pink)
    }

    // MARK: - Saving

    @Test("Edits reach the file after the pause, not on every tick, and the preview follows each one")
    func saveIsDebouncedAndPreviewIsLive() async throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let clock = ManualClock()
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: clock)

        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }
        #expect(fixture.preview.drafts[Self.midnightId]?.overrides[.editorText] == Fixture.pink)
        #expect(try onDisk(fixture).overrides[.editorText] == nil)

        await clock.waitUntilSleeping()
        clock.advance(by: ThemeEditorModel.defaultSaveDelay)
        try await waitUntil { (try? self.onDisk(fixture).overrides[.editorText]) == Fixture.pink }
        editor.close()
        #expect(fixture.preview.ended == [Self.midnightId])
        #expect(fixture.preview.drafts.isEmpty)
    }

    @Test("Closing writes what the pause had not written yet")
    func closeFlushesThePendingSave() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: ManualClock())

        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }
        #expect(editor.prepareToClose() == .close)
        editor.close()

        #expect(try onDisk(fixture).overrides[.editorText] == Fixture.pink)
    }

    /// Quitting closes no window, so the termination flush is the only write the typed text gets.
    @Test("A flush writes the name and author still being typed")
    func flushCommitsTheFields() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: ManualClock())

        editor.nameText = "Night Owl"
        editor.authorText = "Ada"
        #expect(editor.flush())

        let saved = try onDisk(fixture)
        #expect(saved.name == "Night Owl")
        #expect(saved.author == "Ada")
        editor.close()
    }

    @Test("A save that fails reports why, and closing then asks rather than trapping the window")
    func saveFailureLeavesTheWindowClosable() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: ManualClock())
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.themes.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.themes.path) }

        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }
        #expect(!editor.flush())
        guard case let .saveFailed(name, _) = editor.alert else {
            Issue.record("Expected a save failure, got \(String(describing: editor.alert))")
            return
        }
        #expect(name == "Midnight")
        #expect(editor.isEditable)

        guard case .confirmDiscard = editor.prepareToClose() else {
            Issue.record("Closing over a failed save should ask first")
            return
        }
        var closeRequests = 0
        editor.onRequestClose = { closeRequests += 1 }
        editor.requestClose()
        #expect(closeRequests == 1)
        editor.close()
    }

    // MARK: - Changes from elsewhere

    @Test("A file changed outside TablePro replaces the draft, with the alert, and no save writes over it")
    func externalChangeIsAdopted() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: ManualClock())
        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }

        var newer = try onDisk(fixture)
        newer.overrides[.syntaxKeyword] = Fixture.green
        try ThemeFileFormat.encode(newer).write(to: fixture.themes.appendingPathComponent("Midnight.json"))
        fixture.catalog.reloadSynchronously()

        #expect(editor.alert == .changedOnDisk(name: "Midnight"))
        #expect(editor.draft.overrides[.syntaxKeyword] == Fixture.green)
        #expect(editor.draft.overrides[.editorText] == nil)
        #expect(!editor.undoManager.canUndo)
        #expect(editor.flush())
        #expect(try onDisk(fixture) == newer)
        editor.close()
    }

    /// The list shows the later of two "Midnight" themes as "Midnight 2" so a popup can tell them
    /// apart. That is not a change to this theme's file, and the suffix must never be written to it.
    @Test("A same-named theme arriving elsewhere neither raises a conflict nor renames the file")
    func sameNamedArrivalIsNotAConflict() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: ManualClock())

        try fixture.install(Fixture.theme("user.0000aaaa", "Midnight"), as: "Arrived.json")
        #expect(fixture.catalog.theme(id: Self.midnightId)?.name == "Midnight 2")

        #expect(editor.alert == nil)
        #expect(editor.draft.name == "Midnight")
        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }
        #expect(editor.flush())
        #expect(editor.alert == nil)
        #expect(try onDisk(fixture).name == "Midnight")
        #expect(try onDisk(fixture).overrides[.editorText] == Fixture.pink)
        editor.close()
    }

    @Test("A save over a file changed since it was read adopts the newer file instead")
    func saveConflictAdoptsTheNewerFile() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: ManualClock())
        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }

        var newer = try onDisk(fixture)
        newer.name = "Midnight Blue"
        try ThemeFileFormat.encode(newer).write(to: fixture.themes.appendingPathComponent("Midnight.json"))

        #expect(!editor.flush())
        #expect(editor.alert == .changedOnDisk(name: "Midnight Blue"))
        #expect(editor.draft.name == "Midnight Blue")
        #expect(try onDisk(fixture).name == "Midnight Blue")
        #expect(try onDisk(fixture).overrides[.editorText] == nil)
        editor.close()
    }

    @Test("A theme deleted outside TablePro is not written back, and Keep Theme saves it under a new id")
    func externalDeleteDoesNotResurrect() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        fixture.selection.themeSelection.preferredDarkThemeId = Self.midnightId
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: ManualClock())
        var renamed: (String, String)?
        editor.onIdentifierChange = { renamed = ($0, $1) }
        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }

        try FileManager.default.removeItem(at: fixture.themes.appendingPathComponent("Midnight.json"))
        fixture.catalog.reloadSynchronously()

        #expect(editor.alert == .deletedOnDisk(name: "Midnight"))
        #expect(editor.isDetached)
        #expect(!editor.isEditable)
        #expect(fixture.preview.ended == [Self.midnightId])
        #expect(editor.flush())
        #expect(editor.prepareToClose() == .close)
        #expect(try fixture.fileNames().isEmpty)

        editor.keepAsNewTheme()
        #expect(!editor.isDetached)
        #expect(editor.draft.id != Self.midnightId)
        #expect(editor.draft.overrides[.editorText] == Fixture.pink)
        #expect(try fixture.fileNames() == ["\(editor.draft.id).json"])
        #expect(fixture.selection.themeSelection.preferredDarkThemeId == editor.draft.id)
        #expect(renamed?.0 == Self.midnightId)
        #expect(renamed?.1 == editor.draft.id)
        editor.close()
    }

    @Test("A file that changed into one that no longer loads stops the editor without a second file")
    func unreadableFileStopsTheEditor() throws {
        let fixture = try Fixture()
        try midnight(in: fixture)
        let editor = try fixture.makeEditor(for: Self.midnightId, clock: ManualClock())
        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }

        try Data("{".utf8).write(to: fixture.themes.appendingPathComponent("Midnight.json"))
        fixture.catalog.reloadSynchronously()

        #expect(editor.alert == .unreadableOnDisk(name: "Midnight"))
        #expect(editor.isDetached)
        #expect(editor.prepareToClose() == .close)
        #expect(try fixture.fileNames() == ["Midnight.json"])
        editor.close()
    }

    // MARK: - Built-in themes

    @Test("A built-in theme opens read-only and ignores edits")
    func builtInIsReadOnly() throws {
        let fixture = try Fixture()
        let editor = try fixture.makeEditor(for: BuiltInThemes.defaultDarkId)

        #expect(editor.isReadOnly)
        Fixture.step(editor) { editor.setColor(Fixture.pink, for: .editorText) }
        Fixture.step(editor) { editor.setAppearance(.light) }

        #expect(editor.draft == BuiltInThemes.dark)
        #expect(editor.prepareToClose() == .close)
        #expect(fixture.preview.drafts.isEmpty)
        editor.close()
    }
}

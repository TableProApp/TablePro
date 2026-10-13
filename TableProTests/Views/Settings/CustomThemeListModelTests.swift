@testable import TablePro
import Testing

struct CustomThemeListModelTests {
    private func theme(_ id: String, _ name: String, _ appearance: ThemeAppearance) -> ThemeDefinition {
        ThemeDefinition(id: id, name: name, author: "", appearance: appearance, overrides: [:])
    }

    private var themes: [ThemeDefinition] {
        BuiltInThemes.all + [
            theme("tablepro.dracula", "Dracula", .dark),
            theme("user.aaaa0001", "Paper", .light),
            theme("user.aaaa0002", "Midnight", .dark),
        ]
    }

    private let refused = RejectedThemeRecord(
        path: "/Themes/Broken.json",
        fileName: "Broken.json",
        reason: "The file does not declare a theme format version."
    )

    @Test("Only user themes are listed, in catalog order, with refused files kept apart")
    func listsUserThemesAndRefusedFiles() {
        let model = CustomThemeListModel(themes: themes, rejected: [refused])
        #expect(model.themes.map(\.id) == ["user.aaaa0001", "user.aaaa0002"])
        #expect(model.notLoaded == [refused])
        #expect(!model.isEmpty)
    }

    @Test("Built-in themes alone leave the list empty")
    func builtInsAloneAreEmpty() {
        #expect(CustomThemeListModel(themes: themes.filter(\.isBuiltIn), rejected: []).isEmpty)
    }

    @Test("A row resolves to its own theme or file and to nothing else")
    func itemsResolve() {
        let model = CustomThemeListModel(themes: themes, rejected: [refused])
        #expect(model.theme(for: .theme("user.aaaa0001"))?.name == "Paper")
        #expect(model.theme(for: .theme("tablepro.dracula")) == nil)
        #expect(model.theme(for: .notLoaded(path: refused.path)) == nil)
        #expect(model.theme(for: nil) == nil)
        #expect(model.record(for: .notLoaded(path: refused.path)) == refused)
        #expect(model.record(for: .theme("user.aaaa0001")) == nil)
    }

    @Test("A rename trims, and ignores an empty or unchanged name")
    func renameTrimsAndIgnoresNoChange() {
        #expect(ThemeNaming.renamed("  Midnight  ", current: "Dracula Copy", takenNames: []) == "Midnight")
        #expect(ThemeNaming.renamed("   ", current: "Dracula Copy", takenNames: []) == nil)
        #expect(ThemeNaming.renamed("Dracula Copy", current: "Dracula Copy", takenNames: []) == nil)
    }

    @Test("A rename to a name another theme has is numbered, never duplicated")
    func renameNumbersATakenName() {
        #expect(ThemeNaming.renamed("Dracula", current: "Mine", takenNames: ["Dracula"]) == "Dracula 2")
        #expect(ThemeNaming.renamed("Dracula", current: "Mine", takenNames: ["Dracula", "Dracula 2"]) == "Dracula 3")
        #expect(ThemeNaming.renamed("Dracula", current: "Dracula 2", takenNames: ["Dracula"]) == nil)
    }

    @Test("Deleting a theme sends only the slots that held it back to their built-ins")
    func deletingReleasesOnlyItsSlots() {
        let settings = AppearanceSettings(
            appearanceMode: .auto,
            preferredLightThemeId: "user.aaaa0001",
            preferredDarkThemeId: "user.aaaa0002"
        )

        let released = settings.releasing(themeId: "user.aaaa0002")
        #expect(released.preferredLightThemeId == "user.aaaa0001")
        #expect(released.preferredDarkThemeId == BuiltInThemes.defaultDarkId)
        #expect(released.appearanceMode == .auto)

        #expect(settings.releasing(themeId: "user.other") == settings)
    }
}

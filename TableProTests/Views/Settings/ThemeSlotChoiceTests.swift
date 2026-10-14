@testable import TablePro
import Testing

struct ThemeSlotChoiceTests {
    private func theme(_ id: String, _ name: String, _ appearance: ThemeAppearance) -> ThemeDefinition {
        ThemeDefinition(id: id, name: name, author: "", appearance: appearance, overrides: [:])
    }

    private var catalog: [ThemeDefinition] {
        BuiltInThemes.all + [
            theme("tablepro.dracula", "Dracula", .dark),
            theme("user.aaaa0001", "Paper", .light),
            theme("user.aaaa0002", "Midnight", .dark),
        ]
    }

    @Test("Each popup lists only its own appearance, built-in themes before custom ones")
    func optionsFollowTheSlot() {
        let light = ThemeSlotChoice(slot: .light, savedId: BuiltInThemes.defaultLightId, themes: catalog)
        #expect(light.builtIn.map(\.id) == [BuiltInThemes.defaultLightId])
        #expect(light.custom.map(\.id) == ["user.aaaa0001"])

        let dark = ThemeSlotChoice(slot: .dark, savedId: BuiltInThemes.defaultDarkId, themes: catalog)
        #expect(dark.builtIn.map(\.id) == [BuiltInThemes.defaultDarkId, "tablepro.dracula"])
        #expect(dark.custom.map(\.id) == ["user.aaaa0002"])
    }

    @Test("A saved theme that is on this Mac is shown with no note")
    func presentThemeIsShown() {
        let choice = ThemeSlotChoice(slot: .dark, savedId: "user.aaaa0002", themes: catalog)
        #expect(choice.selectedId == "user.aaaa0002")
        #expect(choice.note == nil)
        #expect(choice.noteMessage == nil)
    }

    /// Appearance settings sync and theme files do not, so another Mac's choice arrives as an id
    /// this Mac has never seen.
    @Test("A saved theme this Mac does not have shows the built-in in use and says why")
    func missingThemeIsExplained() {
        let choice = ThemeSlotChoice(slot: .dark, savedId: "user.synced01", themes: catalog)
        #expect(choice.selectedId == BuiltInThemes.defaultDarkId)
        #expect(choice.note == .notOnThisMac(fallback: BuiltInThemes.dark.name))
        #expect(choice.noteMessage != nil)
    }

    @Test("A saved theme of the other appearance shows the built-in in use and names the theme")
    func wrongAppearanceIsExplained() {
        let choice = ThemeSlotChoice(slot: .light, savedId: "user.aaaa0002", themes: catalog)
        #expect(choice.selectedId == BuiltInThemes.defaultLightId)
        #expect(choice.note == .wrongAppearance(theme: "Midnight", fallback: BuiltInThemes.light.name))
        #expect(choice.noteMessage != nil)
    }

    @Test("The popup shows the same theme the engine resolves")
    func agreesWithTheResolver() {
        for savedId in ["user.aaaa0002", "user.missing", "user.aaaa0001", "tablepro.dracula"] {
            let choice = ThemeSlotChoice(slot: .dark, savedId: savedId, themes: catalog)
            let resolved = ThemeResolver.resolve(
                mode: .dark,
                lightThemeId: BuiltInThemes.defaultLightId,
                darkThemeId: savedId,
                themes: catalog,
                systemIsDark: true
            )
            #expect(choice.selectedId == resolved.active.id, "\(savedId)")
        }
    }
}

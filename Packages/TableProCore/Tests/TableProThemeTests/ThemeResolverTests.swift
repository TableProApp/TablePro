import TableProTheme
import Testing

struct ThemeResolverTests {
    private static func theme(_ id: String, _ appearance: ThemeAppearance) -> ThemeDefinition {
        var copy = ThemeDefinition.default(for: appearance)
        copy.id = id
        copy.name = id
        return copy
    }

    private static let sample = [theme("user.light", .light), theme("user.dark", .dark)]

    private static var catalog: [ThemeDefinition] {
        [.defaultLight, .defaultDark] + sample
    }

    private static func resolve(
        light: String = ThemeDefinition.defaultLight.id,
        dark: String = ThemeDefinition.defaultDark.id,
        appearance: ThemeAppearance = .light
    ) -> ThemeSelection {
        ThemeResolver.resolve(lightThemeId: light, darkThemeId: dark, themes: catalog, effectiveAppearance: appearance)
    }

    // MARK: - Resolver

    @Test("A theme that exists and fits its slot is used")
    func fittingThemesResolve() {
        let selection = Self.resolve(light: "user.light", dark: "user.dark")
        #expect(selection.pair.light.id == "user.light")
        #expect(selection.pair.dark.id == "user.dark")
    }

    /// Falling back to Default Light whichever slot asked painted a white editor inside dark chrome.
    @Test("A missing theme falls back to its own slot's default")
    func missingThemeFallsBackPerSlot() {
        let selection = Self.resolve(light: "user.deleted", dark: "user.deleted")
        #expect(selection.pair.light == .defaultLight)
        #expect(selection.pair.dark == .defaultDark)
    }

    @Test("A theme of the wrong appearance falls back to that slot's default")
    func misfitThemeFallsBackPerSlot() {
        let selection = Self.resolve(light: "user.dark", dark: "user.light")
        #expect(selection.pair.light.id == ThemeDefinition.defaultLight.id)
        #expect(selection.pair.dark.id == ThemeDefinition.defaultDark.id)

        let swapped = Self.resolve(light: ThemeDefinition.defaultDark.id, dark: ThemeDefinition.defaultLight.id)
        #expect(swapped.pair.light.id == ThemeDefinition.defaultLight.id)
        #expect(swapped.pair.dark.id == ThemeDefinition.defaultDark.id)
    }

    @Test("The active theme is the pair's theme for the appearance given")
    func activeThemeFollowsTheEffectiveAppearance() {
        let dark = Self.resolve(light: "user.light", dark: "user.dark", appearance: .dark)
        #expect(dark.effectiveAppearance == .dark)
        #expect(dark.active.id == "user.dark")

        let light = Self.resolve(light: "user.light", dark: "user.dark", appearance: .light)
        #expect(light.effectiveAppearance == .light)
        #expect(light.active.id == "user.light")
    }

    @Test("The built-in pair is the two defaults")
    func builtInPair() {
        #expect(ThemePair.builtIn.light == .defaultLight)
        #expect(ThemePair.builtIn.dark == .defaultDark)
        #expect(ThemePair.builtIn[.dark] == .defaultDark)
    }

    // MARK: - Eligible themes

    @Test("A theme fits only the slot of its own appearance")
    func fitsMatchesAppearance() {
        #expect(ThemeSlotValidation.fits(.light, slot: .light))
        #expect(ThemeSlotValidation.fits(.dark, slot: .dark))
        #expect(!ThemeSlotValidation.fits(.dark, slot: .light))
        #expect(!ThemeSlotValidation.fits(.light, slot: .dark))
    }

    @Test("Only fitting themes are listed")
    func listIsFiltered() {
        let eligible = ThemeSlotValidation.eligibleThemes(Self.catalog, slot: .light, keeping: nil)
        #expect(eligible.map(\.id) == [ThemeDefinition.defaultLight.id, "user.light"])
    }

    /// The row the user is standing on is never filtered away, because the alternative was to
    /// rewrite their saved theme so the filter came out true.
    @Test("A misfit theme stays listed while it is the one selected")
    func selectedMisfitIsKept() {
        let eligible = ThemeSlotValidation.eligibleThemes(Self.sample, slot: .light, keeping: "user.dark")
        #expect(eligible.map(\.id) == ["user.light", "user.dark"])
    }

    @Test("Keeping a fitting selection does not list it twice")
    func keptSelectionIsNotDuplicated() {
        let eligible = ThemeSlotValidation.eligibleThemes(Self.sample, slot: .light, keeping: "user.light")
        #expect(eligible.map(\.id) == ["user.light"])
    }

    @Test("An unknown selected id adds nothing")
    func unknownSelectionAddsNothing() {
        let eligible = ThemeSlotValidation.eligibleThemes(Self.sample, slot: .dark, keeping: "user.missing")
        #expect(eligible.map(\.id) == ["user.dark"])
    }
}

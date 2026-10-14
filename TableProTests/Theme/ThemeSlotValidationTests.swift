//
//  ThemeSlotValidationTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct ThemeSlotValidationTests {
    private static func theme(_ id: String, _ appearance: ThemeAppearance) -> ThemeDefinition {
        var copy = BuiltInThemes.default(for: appearance)
        copy.id = id
        copy.name = id
        return copy
    }

    private static let sample = [theme("user.light", .light), theme("user.dark", .dark)]

    private static var catalog: [ThemeDefinition] { BuiltInThemes.all + sample }

    private static func resolve(
        mode: AppAppearanceMode = .auto,
        light: String = BuiltInThemes.defaultLightId,
        dark: String = BuiltInThemes.defaultDarkId,
        systemIsDark: Bool = false
    ) -> ThemeSelection {
        ThemeResolver.resolve(
            mode: mode,
            lightThemeId: light,
            darkThemeId: dark,
            themes: catalog,
            systemIsDark: systemIsDark
        )
    }

    // MARK: - Resolver

    @Test("A theme that exists and fits its slot is used")
    func fittingThemesResolve() {
        let selection = Self.resolve(light: "user.light", dark: "user.dark")
        #expect(selection.pair.light.id == "user.light")
        #expect(selection.pair.dark.id == "user.dark")
    }

    /// A slot whose theme is missing falls back to that slot's own built-in. Falling back to
    /// Default Light whichever slot asked painted a white editor inside dark chrome.
    @Test("A missing theme falls back to its own slot's built-in")
    func missingThemeFallsBackPerSlot() {
        let selection = Self.resolve(light: "user.deleted", dark: "user.deleted")
        #expect(selection.pair.light.id == BuiltInThemes.defaultLightId)
        #expect(selection.pair.dark.id == BuiltInThemes.defaultDarkId)
    }

    @Test("A theme of the wrong appearance falls back to that slot's built-in")
    func misfitThemeFallsBackPerSlot() {
        let selection = Self.resolve(light: "user.dark", dark: "user.light")
        #expect(selection.pair.light.id == BuiltInThemes.defaultLightId)
        #expect(selection.pair.dark.id == BuiltInThemes.defaultDarkId)

        let swappedDefaults = Self.resolve(light: BuiltInThemes.defaultDarkId, dark: BuiltInThemes.defaultLightId)
        #expect(swappedDefaults.pair.light.id == BuiltInThemes.defaultLightId)
        #expect(swappedDefaults.pair.dark.id == BuiltInThemes.defaultDarkId)
    }

    @Test("Auto follows the system appearance, forced modes ignore it")
    func autoFollowsSystem() {
        #expect(ThemeResolver.effectiveAppearance(mode: .auto, systemIsDark: true) == .dark)
        #expect(ThemeResolver.effectiveAppearance(mode: .auto, systemIsDark: false) == .light)
        #expect(ThemeResolver.effectiveAppearance(mode: .light, systemIsDark: true) == .light)
        #expect(ThemeResolver.effectiveAppearance(mode: .dark, systemIsDark: false) == .dark)
    }

    @Test("The active theme is the pair's theme for the effective appearance")
    func activeThemeFollowsTheEffectiveAppearance() {
        let dark = Self.resolve(mode: .auto, light: "user.light", dark: "user.dark", systemIsDark: true)
        #expect(dark.effectiveAppearance == .dark)
        #expect(dark.active.id == "user.dark")

        let light = Self.resolve(mode: .auto, light: "user.light", dark: "user.dark", systemIsDark: false)
        #expect(light.effectiveAppearance == .light)
        #expect(light.active.id == "user.light")

        let forced = Self.resolve(mode: .light, light: "user.light", dark: "user.dark", systemIsDark: true)
        #expect(forced.active.id == "user.light")
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
        #expect(eligible.map(\.id) == [BuiltInThemes.defaultLightId, "user.light"])
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

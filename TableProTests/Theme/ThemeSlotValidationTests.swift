//
//  ThemeSlotValidationTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

@Suite("Theme slot validation")
struct ThemeSlotValidationTests {
    @Test("A matching theme fits its slot")
    func matchingThemeFits() {
        #expect(ThemeSlotValidation.fits(.light, slot: .light))
        #expect(ThemeSlotValidation.fits(.dark, slot: .dark))
    }

    @Test("A contradicting theme does not fit")
    func contradictingThemeDoesNotFit() {
        #expect(ThemeSlotValidation.fits(.dark, slot: .light) == false)
        #expect(ThemeSlotValidation.fits(.light, slot: .dark) == false)
    }

    private func theme(_ id: String, _ appearance: ThemeAppearance) -> ThemeDefinition {
        var copy = BuiltInThemes.default(for: appearance)
        copy.id = id
        return copy
    }

    private var sample: [ThemeDefinition] {
        [theme("light", .light), theme("dark", .dark)]
    }

    @Test("Only fitting themes stay in the list")
    func listIsFiltered() {
        let eligible = ThemeSlotValidation.eligibleThemes(sample, slot: .light, keeping: nil)
        #expect(eligible.map(\.id) == ["light"])
    }

    /// The row the user is standing on can never be filtered away, because the alternative was to
    /// rewrite their saved theme so the filter came out true.
    @Test("A contradicting theme stays listed while it is the one selected")
    func selectedContradictingThemeIsKept() {
        let eligible = ThemeSlotValidation.eligibleThemes(sample, slot: .light, keeping: "dark")
        #expect(eligible.map(\.id) == ["light", "dark"])
    }

    @Test("Keeping a selection does not duplicate a theme that already fits")
    func keptSelectionIsNotDuplicated() {
        let eligible = ThemeSlotValidation.eligibleThemes(sample, slot: .light, keeping: "light")
        #expect(eligible.map(\.id) == ["light"])
    }

    @Test("An unknown selected id adds nothing to the list")
    func unknownSelectionAddsNothing() {
        let eligible = ThemeSlotValidation.eligibleThemes(sample, slot: .dark, keeping: "does.not.exist")
        #expect(eligible.map(\.id) == ["dark"])
    }

    /// A slot whose theme is missing, rejected, or of the wrong appearance falls back to that
    /// slot's own built-in. Falling back to Default Light whichever slot asked painted a white
    /// editor inside dark chrome.
    @Test("A dark slot that cannot resolve falls back to Default Dark")
    func darkSlotFallsBackToDefaultDark() {
        let selection = ThemeResolver.resolve(
            mode: .dark,
            lightThemeId: BuiltInThemes.defaultLightId,
            darkThemeId: "user.deleted",
            themes: BuiltInThemes.all,
            systemIsDark: true
        )

        #expect(selection.pair.dark.id == BuiltInThemes.defaultDarkId)
        #expect(selection.active.appearance == .dark)
    }

    @Test("A light theme sitting in the dark slot falls back to Default Dark")
    func misfitThemeInDarkSlotFallsBack() {
        let selection = ThemeResolver.resolve(
            mode: .dark,
            lightThemeId: BuiltInThemes.defaultLightId,
            darkThemeId: BuiltInThemes.defaultLightId,
            themes: BuiltInThemes.all,
            systemIsDark: true
        )

        #expect(selection.pair.dark.id == BuiltInThemes.defaultDarkId)
    }

    @Test("Auto follows the system appearance")
    func autoFollowsSystem() {
        #expect(ThemeResolver.effectiveAppearance(mode: .auto, systemIsDark: true) == .dark)
        #expect(ThemeResolver.effectiveAppearance(mode: .auto, systemIsDark: false) == .light)
        #expect(ThemeResolver.effectiveAppearance(mode: .light, systemIsDark: true) == .light)
        #expect(ThemeResolver.effectiveAppearance(mode: .dark, systemIsDark: false) == .dark)
    }
}

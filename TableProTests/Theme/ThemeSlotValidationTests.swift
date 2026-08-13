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

    @Test("An auto theme fits both slots")
    func autoFitsBoth() {
        #expect(ThemeSlotValidation.fits(.auto, slot: .light))
        #expect(ThemeSlotValidation.fits(.auto, slot: .dark))
    }

    private func theme(_ id: String, _ appearance: ThemeAppearance) -> ThemeDefinition {
        var copy = ThemeDefinition.default
        copy.id = id
        copy.appearance = appearance
        return copy
    }

    @Test("A contradicting slot re-anchors to the default")
    func contradictingSlotReanchors() {
        let themes = [theme("light", .light), theme("dark", .dark)]
        let resolved = ThemeSlotValidation.resolvedThemeId(
            current: "dark",
            slot: .light,
            themes: themes,
            defaultId: "light"
        )
        #expect(resolved == "light")
    }

    @Test("A matching slot is left alone")
    func matchingSlotUntouched() {
        let themes = [theme("light", .light), theme("dark", .dark)]
        let resolved = ThemeSlotValidation.resolvedThemeId(
            current: "light",
            slot: .light,
            themes: themes,
            defaultId: "light"
        )
        #expect(resolved == "light")
    }

    @Test("An auto theme survives either slot")
    func autoThemeSurvives() {
        let themes = [theme("auto", .auto)]
        #expect(
            ThemeSlotValidation.resolvedThemeId(
                current: "auto", slot: .dark, themes: themes, defaultId: "dark"
            ) == "auto"
        )
    }

    @Test("An unknown theme id falls back to the default")
    func unknownIdFallsBack() {
        let resolved = ThemeSlotValidation.resolvedThemeId(
            current: "does.not.exist",
            slot: .dark,
            themes: [theme("dark", .dark)],
            defaultId: "dark"
        )
        #expect(resolved == "dark")
    }

    @Test("Only fitting themes stay in the list")
    func listIsFiltered() {
        let themes = [theme("light", .light), theme("dark", .dark), theme("auto", .auto)]
        let eligible = ThemeSlotValidation.eligibleThemes(themes, slot: .light)
        #expect(eligible.map(\.id) == ["light", "auto"])
    }
}

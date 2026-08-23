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

    private var sample: [ThemeDefinition] {
        [theme("light", .light), theme("dark", .dark), theme("auto", .auto)]
    }

    @Test("Only fitting themes stay in the list")
    func listIsFiltered() {
        let eligible = ThemeSlotValidation.eligibleThemes(sample, slot: .light, keeping: nil)
        #expect(eligible.map(\.id) == ["light", "auto"])
    }

    /// The row the user is standing on can never be filtered away, because the alternative was to
    /// rewrite their saved theme so the filter came out true.
    @Test("A contradicting theme stays listed while it is the one selected")
    func selectedContradictingThemeIsKept() {
        let eligible = ThemeSlotValidation.eligibleThemes(sample, slot: .light, keeping: "dark")
        #expect(eligible.map(\.id) == ["light", "dark", "auto"])
    }

    @Test("Keeping a selection does not duplicate a theme that already fits")
    func keptSelectionIsNotDuplicated() {
        let eligible = ThemeSlotValidation.eligibleThemes(sample, slot: .light, keeping: "light")
        #expect(eligible.map(\.id) == ["light", "auto"])
    }

    @Test("An unknown selected id adds nothing to the list")
    func unknownSelectionAddsNothing() {
        let eligible = ThemeSlotValidation.eligibleThemes(sample, slot: .dark, keeping: "does.not.exist")
        #expect(eligible.map(\.id) == ["dark", "auto"])
    }
}

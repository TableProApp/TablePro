import TableProTheme
import Testing

struct DefaultThemesTests {
    @Test("The defaults have fixed ids, names and appearances, and set no color")
    func defaultsAreEmpty() {
        #expect(ThemeDefinition.defaultLight.id == "tablepro.default-light")
        #expect(ThemeDefinition.defaultDark.id == "tablepro.default-dark")
        #expect(ThemeDefinition.defaultLight.name == "Default Light")
        #expect(ThemeDefinition.defaultDark.name == "Default Dark")
        #expect(ThemeDefinition.defaultLight.author == "TablePro")
        #expect(ThemeDefinition.defaultLight.appearance == .light)
        #expect(ThemeDefinition.defaultDark.appearance == .dark)
        #expect(ThemeDefinition.defaultLight.overrides.isEmpty)
        #expect(ThemeDefinition.defaultDark.overrides.isEmpty)
        #expect(ThemeDefinition.defaultLight.isBuiltIn)
    }

    @Test("Each appearance has its own default")
    func defaultPerAppearance() {
        #expect(ThemeDefinition.default(for: .light) == .defaultLight)
        #expect(ThemeDefinition.default(for: .dark) == .defaultDark)
        #expect(ThemeDefinition.defaultId(for: .dark) == "tablepro.default-dark")
        #expect(ThemeDefinition.isDefault("tablepro.default-light"))
        #expect(ThemeDefinition.isDefault("tablepro.default-dark"))
        #expect(!ThemeDefinition.isDefault("tablepro.dracula"))
    }

    private static func hexes(_ appearance: ThemeAppearance, highContrast: Bool) -> [ThemeSlot: String] {
        DefaultSyntaxPalette.colors(for: appearance, highContrast: highContrast).mapValues(\.hex)
    }

    /// Xcode 27.1 `Default (Light).xccolortheme`: keyword, string, number, comment, system function
    /// and system type.
    @Test("Default Light syntax is Xcode's Default (Light)")
    func standardLight() {
        #expect(Self.hexes(.light, highContrast: false) == [
            .syntaxKeyword: "#9B2393",
            .syntaxString: "#C41A16",
            .syntaxNumber: "#1C00CF",
            .syntaxComment: "#5D6C79",
            .syntaxFunction: "#6C36A9",
            .syntaxType: "#3900A0",
            .syntaxNull: "#9B2393",
        ])
    }

    @Test("Default Dark syntax is Xcode's Default (Dark)")
    func standardDark() {
        #expect(Self.hexes(.dark, highContrast: false) == [
            .syntaxKeyword: "#FC5FA3",
            .syntaxString: "#FC6A5D",
            .syntaxNumber: "#D0BF69",
            .syntaxComment: "#6C7986",
            .syntaxFunction: "#A167E6",
            .syntaxType: "#D0A8FF",
            .syntaxNull: "#FC5FA3",
        ])
    }

    @Test("Under Increase Contrast the syntax is Xcode's High Contrast palette")
    func highContrast() {
        #expect(Self.hexes(.light, highContrast: true) == [
            .syntaxKeyword: "#88007E",
            .syntaxString: "#9B0509",
            .syntaxNumber: "#1C02CF",
            .syntaxComment: "#1A5301",
            .syntaxFunction: "#5C2699",
            .syntaxType: "#330090",
            .syntaxNull: "#88007E",
        ])
        #expect(Self.hexes(.dark, highContrast: true) == [
            .syntaxKeyword: "#FC6BAA",
            .syntaxString: "#FC7467",
            .syntaxNumber: "#D0BC56",
            .syntaxComment: "#7CB554",
            .syntaxFunction: "#C08AFF",
            .syntaxType: "#DEC1FF",
            .syntaxNull: "#FC6BAA",
        ])
    }

    @Test("The palette covers exactly the slots that fall back to the default syntax")
    func paletteCoversDefaultSyntaxSlots() {
        let expected = Set(ThemeSlot.allCases.filter { $0.fallback == .defaultSyntax })
        for appearance in ThemeAppearance.allCases {
            for highContrast in [false, true] {
                let covered = Set(DefaultSyntaxPalette.colors(for: appearance, highContrast: highContrast).keys)
                #expect(covered == expected, "\(appearance) high contrast \(highContrast)")
            }
        }
        #expect(DefaultSyntaxPalette.color(for: .syntaxOperator, appearance: .dark, highContrast: false) == nil)
        #expect(DefaultSyntaxPalette.color(for: .syntaxKeyword, appearance: .dark, highContrast: false)?.hex == "#FC5FA3")
    }

    /// The old defaults carried their syntax as overrides, so a duplicate froze them under Increase
    /// Contrast. An empty default keeps a copy on the adaptive palette.
    @Test("A copy of a default keeps every syntax slot on the default palette")
    func copyOfADefaultStaysAdaptive() {
        var copy = ThemeDefinition.defaultDark
        copy.id = "user.copy"
        for slot in ThemeSlotGroup.syntax.slots where slot != .syntaxOperator {
            #expect(copy.value(for: slot) == .defaultSyntax(slot), "\(slot.rawValue)")
        }
    }
}

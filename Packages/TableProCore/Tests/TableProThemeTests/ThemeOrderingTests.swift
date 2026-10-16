import TableProTheme
import Testing

struct ThemeOrderingTests {
    private static func theme(_ id: String, _ name: String, _ appearance: ThemeAppearance = .dark) -> ThemeDefinition {
        ThemeDefinition(id: id, name: name, author: "", appearance: appearance, overrides: [:])
    }

    @Test("Defaults first, then built-ins by name, then user themes by name")
    func order() {
        let shuffled = [
            Self.theme("user.b", "Zebra", .light),
            Self.theme("tablepro.solarized-light", "Solarized Light", .light),
            Self.theme("user.a", "Amber"),
            ThemeDefinition.defaultDark,
            Self.theme("tablepro.dracula", "Dracula"),
            Self.theme("tablepro.nord", "Nord"),
            ThemeDefinition.defaultLight,
            Self.theme("tablepro.catppuccin-mocha", "Catppuccin Mocha"),
        ]

        #expect(ThemeOrdering.sorted(shuffled).map(\.id) == [
            ThemeDefinition.defaultLight.id,
            ThemeDefinition.defaultDark.id,
            "tablepro.catppuccin-mocha",
            "tablepro.dracula",
            "tablepro.nord",
            "tablepro.solarized-light",
            "user.a",
            "user.b",
        ])
    }

    @Test("A user theme named like a built-in still sorts after every built-in")
    func userThemesFollowBuiltIns() {
        let sorted = ThemeOrdering.sorted([Self.theme("user.x", "Aardvark"), Self.theme("tablepro.nord", "Nord")])
        #expect(sorted.map(\.id) == ["tablepro.nord", "user.x"])
    }

    @Test("Names compare the way Finder does, numbers by value")
    func namesCompareNaturally() {
        let sorted = ThemeOrdering.sorted([Self.theme("user.10", "Theme 10"), Self.theme("user.9", "Theme 9")])
        #expect(sorted.map(\.name) == ["Theme 9", "Theme 10"])
    }

    @Test("Two themes with one name order by id, whichever comes first")
    func tiesOrderById() {
        let first = Self.theme("user.aaaa", "Ocean")
        let second = Self.theme("user.bbbb", "Ocean")

        #expect(ThemeOrdering.sorted([second, first]).map(\.id) == ["user.aaaa", "user.bbbb"])
        #expect(ThemeOrdering.sorted([first, second]).map(\.id) == ["user.aaaa", "user.bbbb"])
        #expect(!ThemeOrdering.areInIncreasingOrder(first, first))
    }
}

import Foundation
import TableProTheme
import Testing

struct ThemeSlotFallbackTests {
    // A typo gives a color no theme draws, so the expectation it sits in fails.
    private static func color(_ hex: String) -> ThemeColor {
        ThemeColor(hex: hex) ?? ThemeColor(red: 1, green: 2, blue: 3, alpha: 4)
    }

    private static func theme(
        _ appearance: ThemeAppearance,
        _ overrides: [ThemeSlot: String]
    ) throws -> ThemeDefinition {
        ThemeDefinition(
            id: "user.fallback",
            name: "Fallback",
            author: "",
            appearance: appearance,
            overrides: try overrides.mapValues { try ThemeColor(validating: $0) }
        )
    }

    // MARK: - The table

    private static let expected: [ThemeSlot: ThemeSlotFallback] = [
        .windowBackdrop: .system,
        .editorBackground: .system,
        .editorText: .system,
        .editorCursor: .system,
        .editorSelection: .system,
        .editorCurrentLine: .system,
        .editorCurrentStatement: .system,
        .editorLineNumber: .system,
        .editorInvisibles: .system,
        .syntaxKeyword: .defaultSyntax,
        .syntaxString: .defaultSyntax,
        .syntaxNumber: .defaultSyntax,
        .syntaxComment: .defaultSyntax,
        .syntaxNull: .defaultSyntax,
        .syntaxOperator: .slot(.editorText),
        .syntaxFunction: .defaultSyntax,
        .syntaxType: .defaultSyntax,
        .gridBackground: .system,
        .gridText: .system,
        .gridAlternateRow: .derived(base: .gridBackground, rule: .stripe(toward: .gridText)),
        .gridLine: .system,
        .gridNullValue: .system,
        .gridBoolTrue: .slot(.gridText),
        .gridBoolFalse: .slot(.gridText),
        .gridRowNumber: .system,
        .gridModified: .system,
        .gridInserted: .system,
        .gridDeleted: .system,
        .gridDeletedText: .system,
    ]

    @Test("Every slot has its fallback rule", arguments: ThemeSlot.allCases)
    func fallbackTable(slot: ThemeSlot) {
        #expect(slot.fallback == Self.expected[slot])
    }

    @Test("The table covers every slot")
    func tableCoversEverySlot() {
        #expect(Set(Self.expected.keys) == Set(ThemeSlot.allCases))
    }

    // A rule that named another dependent slot would chain, and two such rules could loop.
    @Test("A rule only names slots that fall back to the system themselves")
    func rulesNeverChain() {
        for slot in ThemeSlot.allCases {
            let named: [ThemeSlot]
            switch slot.fallback {
            case .system, .defaultSyntax: named = []
            case let .slot(source): named = [source]
            case let .derived(base, .stripe(toward)): named = [base, toward]
            }
            for other in named {
                #expect(other.fallback == .system, "\(slot.rawValue) names \(other.rawValue)")
            }
        }
    }

    // MARK: - Under no theme

    @Test("Under a default theme every slot draws the system or the default syntax", arguments: ThemeAppearance.allCases)
    func defaultsDrawNative(appearance: ThemeAppearance) {
        let theme = ThemeDefinition.default(for: appearance)
        for slot in ThemeSlot.allCases {
            let value = theme.value(for: slot)
            switch slot.fallback {
            case .defaultSyntax:
                #expect(value == .defaultSyntax(slot), "\(slot.rawValue)")
            default:
                #expect(value == .system(slot), "\(slot.rawValue)")
            }
            #expect(!theme.isOverridden(slot), "\(slot.rawValue)")
            #expect(!theme.isOverridden(slot, highContrast: true), "\(slot.rawValue)")
        }
    }

    @Test("An explicit color draws as set")
    func explicitColorDraws() throws {
        let theme = try Self.theme(.dark, [.syntaxKeyword: "#FF79C6", .gridAlternateRow: "#21222C80", .editorCursor: "#F8F8F2"])
        #expect(theme.value(for: .syntaxKeyword) == .themed(Self.color("#FF79C6")))
        #expect(theme.value(for: .gridAlternateRow) == .themed(Self.color("#21222C80")))
        #expect(theme.value(for: .editorCursor) == .themed(Self.color("#F8F8F2")))
        #expect(theme.hasExplicitColor(.syntaxKeyword))
        #expect(!theme.hasExplicitColor(.syntaxString))
    }

    // MARK: - Derived slots

    @Test("A light background-only theme stripes the grid from its own background")
    func backgroundOnlyLight() throws {
        let theme = try Self.theme(.light, [.gridBackground: "#FDF6E3"])

        #expect(theme.value(for: .gridAlternateRow) == .themed(Self.color("#F3ECDA")))
        #expect(theme.isOverridden(.gridAlternateRow))
        #expect(!theme.hasExplicitColor(.gridAlternateRow))
        #expect(theme.value(for: .gridText) == .system(.gridText))
        #expect(theme.value(for: .gridLine) == .system(.gridLine))
    }

    @Test("A dark background-only theme stripes toward white")
    func backgroundOnlyDark() throws {
        let theme = try Self.theme(.dark, [.gridBackground: "#282A36"])

        #expect(theme.value(for: .gridAlternateRow) == .themed(Self.color("#31333E")))
    }

    @Test("The stripe moves toward the theme's own grid text when it sets one")
    func stripeFollowsThemedText() throws {
        let theme = try Self.theme(.dark, [.gridBackground: "#282A36", .gridText: "#F8F8F2"])
        let stripe = try #require(theme.value(for: .gridAlternateRow).themedColor)

        #expect(stripe == Self.color("#30323E"))
        #expect(stripe.isOpaque)
    }

    @Test("Without a themed background the stripe stays native, even with themed text")
    func derivedNeedsTheBase() throws {
        let theme = try Self.theme(.light, [.gridText: "#112233"])
        #expect(theme.value(for: .gridAlternateRow) == .system(.gridAlternateRow))
    }

    @Test("An explicit alternate row wins over the derived one")
    func explicitBeatsDerived() throws {
        let theme = try Self.theme(.light, [.gridBackground: "#FDF6E3", .gridAlternateRow: "#EEE8D5"])
        #expect(theme.value(for: .gridAlternateRow) == .themed(Self.color("#EEE8D5")))
    }

    // MARK: - Slot fallbacks

    @Test("Bools follow themed grid text, and stay native without it")
    func gridTextFollowers() throws {
        let themed = try Self.theme(.dark, [.gridText: "#F8F8F2"])
        let text = Self.color("#F8F8F2")
        for slot in [ThemeSlot.gridBoolTrue, .gridBoolFalse] {
            #expect(themed.value(for: slot) == .themed(text), "\(slot.rawValue)")
            #expect(ThemeDefinition.defaultDark.value(for: slot) == .system(slot), "\(slot.rawValue)")
        }

        let ownBool = try Self.theme(.dark, [.gridText: "#F8F8F2", .gridBoolTrue: "#50FA7B"])
        #expect(ownBool.value(for: .gridBoolTrue) == .themed(Self.color("#50FA7B")))
        #expect(ownBool.value(for: .gridBoolFalse) == .themed(text))
    }

    @Test("Operator falls back to the editor text, themed or native")
    func operatorFollowsEditorText() throws {
        #expect(ThemeDefinition.defaultLight.value(for: .syntaxOperator) == .system(.syntaxOperator))

        let textOnly = try Self.theme(.dark, [.editorText: "#112233"])
        #expect(textOnly.value(for: .syntaxOperator) == .themed(Self.color("#112233")))

        let both = try Self.theme(.dark, [.editorText: "#112233", .syntaxOperator: "#445566"])
        #expect(both.value(for: .syntaxOperator) == .themed(Self.color("#445566")))
    }

    @Test("A syntax slot the theme leaves out takes the default syntax, even when the theme has a default's id")
    func syntaxFallsBackToTheDefault() throws {
        var copy = ThemeDefinition.defaultDark
        copy.overrides[.syntaxKeyword] = Self.color("#FF0000")

        #expect(copy.value(for: .syntaxKeyword) == .themed(Self.color("#FF0000")))
        #expect(copy.value(for: .syntaxString) == .defaultSyntax(.syntaxString))
    }

    // MARK: - Increase Contrast and opacity

    @Test("Under Increase Contrast only the window background yields to the system")
    func windowYieldsToIncreasedContrast() throws {
        let theme = try Self.theme(.dark, [.windowBackdrop: "#282A36", .editorBackground: "#282A36", .gridBackground: "#282A36"])

        #expect(theme.value(for: .windowBackdrop, highContrast: true) == .system(.windowBackdrop))
        #expect(theme.value(for: .windowBackdrop, highContrast: false) == .themed(Self.color("#282A36")))
        #expect(!theme.isOverridden(.windowBackdrop, highContrast: true))
        #expect(theme.isOverridden(.windowBackdrop))
        #expect(theme.isOverridden(.editorBackground, highContrast: true))
        #expect(theme.isOverridden(.gridBackground, highContrast: true))
        #expect(theme.isOverridden(.gridAlternateRow, highContrast: true))
    }

    @Test("A fill that must be opaque draws without the alpha it was given")
    func opaqueSlotsDropAlpha() throws {
        let theme = try Self.theme(.dark, [.windowBackdrop: "#282A3680", .editorSelection: "#44475A80"])
        #expect(theme.value(for: .windowBackdrop) == .themed(Self.color("#282A36")))
        #expect(theme.value(for: .editorSelection) == .themed(Self.color("#44475A80")))
    }
}

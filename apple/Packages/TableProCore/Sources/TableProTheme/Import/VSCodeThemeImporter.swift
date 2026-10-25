import Foundation

// Turns a VS Code color theme into a TablePro theme. Only the result is kept: the catalog saves it
// in the TablePro format, and the VS Code file is never read again.
internal struct VSCodeThemeImporter {
    private static let themeFileSuffix = "-color-theme"

    private let fileURL: URL

    internal init(fileURL: URL) {
        self.fileURL = fileURL
    }

    internal func makeTheme(from root: [String: VSCodeThemeValue], id: String) throws -> ThemeDefinition {
        var source = try VSCodeThemeLoader(fileURL: fileURL).load(root: root)
        let type = VSCodeThemeType(typeName: source.typeName, editorBackground: source.colors["editor.background"])

        // Everything else is flattened over the editor background, which itself sits on nothing themed.
        if let background = source.colors["editor.background"], !background.isOpaque {
            source.colors["editor.background"] = background.composited(over: type.defaultEditorBackground)
        }
        let backdrop = source.colors["editor.background"] ?? type.defaultEditorBackground
        let defaultTokenForeground = source.colors["editor.foreground"] ?? type.defaultEditorForeground

        var evaluator = VSCodeSlotEvaluator(
            colors: source.colors,
            resolver: try TextMateThemeResolver(rules: Self.textMateRules(source.tokenRules, defaultForeground: defaultTokenForeground))
        )

        var overrides: [ThemeSlot: ThemeColor] = [:]
        var hasThemeColor = false
        for slot in ThemeSlot.allCases {
            guard let resolution = evaluator.resolution(for: slot) else { continue }
            let color = resolution.color
            overrides[slot] = slot.requiresOpaque && !color.isOpaque ? color.composited(over: backdrop) : color
            hasThemeColor = hasThemeColor || resolution.isFromTheme
        }
        guard hasThemeColor else { throw ThemeLoadError.noUsableColors }

        let theme = ThemeDefinition(
            id: id,
            name: try themeName(source.name),
            author: source.author.flatMap(Self.singleLine) ?? "",
            appearance: type.appearance,
            overrides: overrides
        )
        return theme.withoutDerivableColors()
    }

    // colorThemeData.ts tokenColors: the editor's own colors as the default rule, then every rule with
    // a scope and settings, foregrounds normalized. An unscoped rule in a JSON theme is dropped.
    private static func textMateRules(_ values: [VSCodeThemeValue], defaultForeground: ThemeColor) -> [TextMateRule] {
        var rules = [TextMateRule(scope: .unscoped, foreground: defaultForeground.hex)]
        for value in values {
            guard
                let entry = value.objectValue,
                let scope = entry["scope"], scope.isTruthy,
                let settings = entry["settings"], settings.isTruthy
            else { continue }

            let foreground = settings.objectValue?["foreground"]?.stringValue.flatMap(VSCodeColorSyntax.normalized)
            rules.append(TextMateRule(scope: textMateScope(scope), foreground: foreground))
        }
        return rules
    }

    private static func textMateScope(_ value: VSCodeThemeValue) -> TextMateRule.Scope {
        switch value {
        case let .string(selector):
            return .selector(selector)
        case let .array(items):
            return .selectors(items.compactMap(\.stringValue))
        default:
            return .unscoped
        }
    }

    // VS Code labels a theme from its package.json and falls back to the file name. A lone file has
    // only its own `name`, so the file name comes next, without `.json` and the `-color-theme` habit.
    private func themeName(_ declared: String?) throws -> String {
        var stem = fileURL.pathExtension.lowercased() == "json"
            ? fileURL.deletingPathExtension().lastPathComponent
            : fileURL.lastPathComponent
        if let suffix = stem.range(of: Self.themeFileSuffix, options: [.caseInsensitive, .anchored, .backwards]) {
            stem.removeSubrange(suffix)
        }

        for candidate in [declared, stem, fileURL.lastPathComponent] {
            if let name = candidate.flatMap(Self.singleLine) {
                return name
            }
        }
        throw ThemeLoadError.invalidName
    }

    // The format takes one line of at most `maximumTextLength` characters, so line breaks and control
    // characters become spaces and a long name is cut rather than refused.
    private static func singleLine(_ text: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let words = text.components(separatedBy: separators).filter { !$0.isEmpty }
        let line = String(words.joined(separator: " ").prefix(ThemeFileFormat.maximumTextLength))
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }
}

private struct VSCodeSlotResolution {
    let color: ThemeColor
    // False for VS Code's own default token color, which says nothing about this theme.
    let isFromTheme: Bool
}

private struct VSCodeSlotEvaluator {
    let colors: [String: ThemeColor]
    let resolver: TextMateThemeResolver
    private var resolved: [ThemeSlot: VSCodeSlotResolution?] = [:]
    private var visiting: Set<ThemeSlot> = []

    init(colors: [String: ThemeColor], resolver: TextMateThemeResolver) {
        self.colors = colors
        self.resolver = resolver
    }

    mutating func resolution(for slot: ThemeSlot) -> VSCodeSlotResolution? {
        if let cached = resolved[slot] {
            return cached
        }
        guard visiting.insert(slot).inserted else { return nil }
        defer { visiting.remove(slot) }

        var result: VSCodeSlotResolution?
        for source in slot.vscodeSources {
            result = resolution(of: source)
            if result != nil {
                break
            }
        }
        resolved[slot] = .some(result)
        return result
    }

    private mutating func resolution(of source: VSCodeColorSource) -> VSCodeSlotResolution? {
        switch source {
        case let .color(key):
            return colors[key].map { VSCodeSlotResolution(color: $0, isFromTheme: true) }
        case let .derived(key, alpha):
            return colors[key].map { VSCodeSlotResolution(color: VSCodeColorSyntax.transparent($0, factor: alpha), isFromTheme: true) }
        case let .token(scopes):
            return resolver.foreground(forScopes: scopes)
                .flatMap(ThemeColor.init(hex:))
                .map { VSCodeSlotResolution(color: $0, isFromTheme: true) }
        case let .slot(other):
            return resolution(for: other)
        case .defaultTokenForeground:
            return ThemeColor(hex: resolver.defaultForeground).map { VSCodeSlotResolution(color: $0, isFromTheme: false) }
        }
    }
}

private extension ThemeDefinition {
    // A slot whose fallback already draws the imported color stays unset, so in the editor it keeps
    // following the slot it derives from. Syntax is always written: an unset syntax slot draws
    // Xcode's color, not the theme's text.
    func withoutDerivableColors() -> ThemeDefinition {
        var result = self
        for slot in ThemeSlot.allCases where slot.section != .syntax && result.hasExplicitColor(slot) {
            switch slot.fallback {
            case .system, .defaultSyntax:
                continue
            case .slot, .derived:
                var unset = result
                unset.overrides[slot] = nil
                if unset.value(for: slot) == result.value(for: slot) {
                    result = unset
                }
            }
        }
        return result
    }
}

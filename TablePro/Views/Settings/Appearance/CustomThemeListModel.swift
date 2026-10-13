import Foundation

internal enum CustomThemeItem: Hashable, Sendable {
    case theme(String)
    case notLoaded(path: String)
}

/// The rows of the Custom Themes list: the user's themes in catalog order, then the files the
/// catalog refused, each with its reason.
internal struct CustomThemeListModel: Equatable {
    internal let themes: [ThemeDefinition]
    internal let notLoaded: [RejectedThemeRecord]

    internal init(themes: [ThemeDefinition], rejected: [RejectedThemeRecord]) {
        self.themes = themes.filter(\.isEditable)
        notLoaded = rejected
    }

    internal var isEmpty: Bool {
        themes.isEmpty && notLoaded.isEmpty
    }

    internal func theme(for item: CustomThemeItem?) -> ThemeDefinition? {
        guard case let .theme(id) = item else { return nil }
        return themes.first { $0.id == id }
    }

    internal func record(for item: CustomThemeItem?) -> RejectedThemeRecord? {
        guard case let .notLoaded(path) = item else { return nil }
        return notLoaded.first { $0.path == path }
    }

    internal static func appearanceLabel(_ appearance: ThemeAppearance) -> String {
        switch appearance {
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
}

internal enum ThemeNaming {
    /// The name a rename stores, or nil when there is nothing to change. A name another theme
    /// already has is numbered the way the catalog numbers copies, because two popup items with
    /// one title cannot be told apart.
    internal static func renamed(_ proposed: String, current: String, takenNames: Set<String>) -> String? {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current else { return nil }
        guard takenNames.contains(trimmed) else { return trimmed }

        var index = 2
        while takenNames.contains("\(trimmed) \(index)") {
            index += 1
        }
        let numbered = "\(trimmed) \(index)"
        return numbered == current ? nil : numbered
    }
}

internal extension AppearanceSettings {
    /// A slot that held a theme the user just deleted goes back to its built-in, so the popup does
    /// not then report that theme as missing.
    func releasing(themeId: String) -> AppearanceSettings {
        var updated = self
        if updated.preferredLightThemeId == themeId {
            updated.preferredLightThemeId = BuiltInThemes.defaultLightId
        }
        if updated.preferredDarkThemeId == themeId {
            updated.preferredDarkThemeId = BuiltInThemes.defaultDarkId
        }
        return updated
    }
}

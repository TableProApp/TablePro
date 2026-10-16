import Combine
import Foundation
import TableProTheme

/// Where a carrier reads its colors. `live` is the engine, which is what every surface in the app
/// draws with. `fixed` draws one definition in both appearances and never changes, so the theme
/// editor can render a draft through the real carriers without making it the active theme.
@MainActor
internal final class ThemeScope {
    internal static let live = ThemeScope(storage: .live)

    private enum Storage {
        case live
        case fixed(definition: ThemeDefinition, palette: ThemePalette, resolved: ResolvedTheme)
    }

    private let storage: Storage

    private init(storage: Storage) {
        self.storage = storage
    }

    /// A new definition is a new scope, so this one never reports a change.
    internal static func fixed(_ definition: ThemeDefinition) -> ThemeScope {
        let source = ThemeSource(pair: ThemePair(light: definition, dark: definition))
        return ThemeScope(storage: .fixed(
            definition: definition,
            palette: ThemePalette(revision: 1, source: source),
            resolved: ResolvedTheme(definition: definition, source: source)
        ))
    }

    internal var activeTheme: ThemeDefinition {
        switch storage {
        case .live: return ThemeEngine.shared.activeTheme
        case let .fixed(definition, _, _): return definition
        }
    }

    internal var palette: ThemePalette {
        switch storage {
        case .live: return ThemeEngine.shared.palette
        case let .fixed(_, palette, _): return palette
        }
    }

    internal var resolved: ResolvedTheme {
        switch storage {
        case .live: return ThemeEngine.shared.resolved
        case let .fixed(_, _, resolved): return resolved
        }
    }

    internal var changes: AnyPublisher<ThemeChange, Never> {
        switch storage {
        case .live: return AppEvents.shared.themeChanged.eraseToAnyPublisher()
        case .fixed: return Empty(completeImmediately: false).eraseToAnyPublisher()
        }
    }
}

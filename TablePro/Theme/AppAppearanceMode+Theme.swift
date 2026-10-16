import Foundation
import TableProTheme

internal extension AppAppearanceMode {
    func effectiveAppearance(systemIsDark: Bool) -> ThemeAppearance {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .auto: return systemIsDark ? .dark : .light
        }
    }
}

import Foundation

/// The one order every theme list uses: Default Light, Default Dark, the other built-ins by name,
/// then the user's themes by name. Two themes with one name keep a stable order by id.
public enum ThemeOrdering {
    public static func areInIncreasingOrder(_ lhs: ThemeDefinition, _ rhs: ThemeDefinition) -> Bool {
        let left = rank(of: lhs)
        let right = rank(of: rhs)
        guard left == right else { return left < right }

        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id < rhs.id
        }
    }

    public static func sorted(_ themes: [ThemeDefinition]) -> [ThemeDefinition] {
        themes.sorted(by: areInIncreasingOrder)
    }

    private static func rank(of theme: ThemeDefinition) -> Int {
        if theme.id == ThemeDefinition.defaultLight.id { return 0 }
        if theme.id == ThemeDefinition.defaultDark.id { return 1 }
        return theme.isBuiltIn ? 2 : 3
    }
}

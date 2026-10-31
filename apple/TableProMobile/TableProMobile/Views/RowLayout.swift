import Foundation

nonisolated enum RowLayout: String, CaseIterable, Identifiable, Sendable {
    case cards
    case grid

    static let storageKey = "com.TablePro.settings.rowLayout"

    var id: String { rawValue }

    /// A choice the user made wins at every width; until then a regular width opens in the grid
    /// and a compact one keeps the cards, which fit a phone held upright.
    static func resolved(preferred: RowLayout?, widthClass: DuoWidthClass) -> RowLayout {
        if let preferred { return preferred }
        switch widthClass {
        case .compact: return .cards
        case .regular: return .grid
        }
    }

    var title: String {
        switch self {
        case .cards: return String(localized: "Cards")
        case .grid: return String(localized: "Grid")
        }
    }

    var systemImage: String {
        switch self {
        case .cards: return "rectangle.grid.1x2"
        case .grid: return "tablecells"
        }
    }
}

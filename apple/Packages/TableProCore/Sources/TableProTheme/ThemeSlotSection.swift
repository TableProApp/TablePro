import Foundation

// The theme editor's grouping: selection colors and row change colors, each chosen as a set, get sections of their own.
public enum ThemeSlotSection: String, CaseIterable, Sendable {
    case window
    case editor
    case syntax
    case dataGrid
    case selection
    case changes

    public var label: String {
        switch self {
        case .window: return String(localized: "Window")
        case .editor: return String(localized: "Editor")
        case .syntax: return String(localized: "Syntax")
        case .dataGrid: return String(localized: "Data Grid")
        case .selection: return String(localized: "Selection")
        case .changes: return String(localized: "Changes")
        }
    }

    public var slots: [ThemeSlot] {
        ThemeSlot.allCases.filter { $0.section == self }
    }
}

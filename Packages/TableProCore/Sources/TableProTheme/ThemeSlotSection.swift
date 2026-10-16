import Foundation

/// The theme editor's grouping. It splits the data grid's file-format group so selection and row
/// change colors, which are chosen together, sit together.
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

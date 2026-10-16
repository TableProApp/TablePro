import Foundation

public enum ThemeSlotGroup: String, CaseIterable, Sendable {
    case window
    case editor
    case syntax
    case dataGrid

    public var label: String {
        switch self {
        case .window: return String(localized: "Window")
        case .editor: return String(localized: "Editor")
        case .syntax: return String(localized: "Syntax")
        case .dataGrid: return String(localized: "Data Grid")
        }
    }

    public var slots: [ThemeSlot] {
        ThemeSlot.allCases.filter { $0.group == self }
    }
}

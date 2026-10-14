//
//  SQLCompletionKind+IconColor.swift
//  TablePro
//

import AppKit
import TableProAutocomplete

extension SQLCompletionKind {
    // The completion panel is system chrome, so each kind keeps its own system color whatever the editor theme.
    var iconColor: NSColor {
        switch self {
        case .keyword: return .systemBlue
        case .table: return .systemTeal
        case .view: return .systemPurple
        case .column: return .systemOrange
        case .function: return .systemPink
        case .schema: return .systemGreen
        case .alias: return .systemGray
        case .operator: return .systemIndigo
        case .favorite: return .systemYellow
        }
    }
}

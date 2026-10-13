//
//  JSONRowColors.swift
//  TablePro
//

import SwiftUI

/// The JSON inspector draws a value in the same tone as the JSON tree viewer, so the two never
/// disagree and neither follows the editor theme.
internal enum JSONRowColors {
    static let key = Color(nsColor: TreeValueTone.key.color)
    static let punctuation = Color.primary
    static let placeholder = Color(nsColor: TreeValueTone.muted.color)

    static func tone(for scalar: JSONScalar) -> TreeValueTone {
        switch scalar {
        case .string, .binary: .string
        case .number: .number
        case .bool, .null: .literal
        }
    }

    static func color(for scalar: JSONScalar) -> Color {
        Color(nsColor: tone(for: scalar).color)
    }
}

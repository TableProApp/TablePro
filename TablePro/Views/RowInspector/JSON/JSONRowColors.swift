//
//  JSONRowColors.swift
//  TablePro
//
//  Syntax colours for the JSON inspector, taken from the active editor theme.
//

import SwiftUI

/// The inspector shows stored values, so its font is the Data Grid Font (`ThemeEngine.valueFont`)
/// while its colours come from the editor palette the SQL editor and the JSON preview already use.
/// Naming a system text style here is what makes a value read differently in the grid and in the
/// inspector the moment the two font settings differ.
struct JSONRowColors {
    let key: Color
    let string: Color
    let number: Color
    let literal: Color
    let punctuation: Color
    let placeholder: Color

    @MainActor
    static func current() -> JSONRowColors {
        let colors = ThemeEngine.shared.colors.editor
        return JSONRowColors(
            key: colors.keywordSwiftUI,
            string: colors.stringSwiftUI,
            number: colors.numberSwiftUI,
            literal: colors.nullSwiftUI,
            punctuation: colors.textSwiftUI,
            placeholder: colors.commentSwiftUI
        )
    }

    func color(for scalar: JSONScalar) -> Color {
        switch scalar {
        case .string, .binary: string
        case .number: number
        case .bool, .null: literal
        }
    }
}

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
        let palette = ThemeEngine.shared.palette
        return JSONRowColors(
            key: palette.color(.syntaxKeyword),
            string: palette.color(.syntaxString),
            number: palette.color(.syntaxNumber),
            literal: palette.color(.syntaxNull),
            punctuation: palette.color(.editorText),
            placeholder: palette.color(.syntaxComment)
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

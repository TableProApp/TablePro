//
//  TreeValueTone+Theme.swift
//  TablePro
//

import AppKit

internal extension TreeValueTone {
    /// The slot the JSON text view draws the same token in: its grammar captures a key as a string,
    /// true, false and null as constants (the NULL color), and leaves braces in the text color.
    var slot: ThemeSlot {
        switch self {
        case .key, .string: return .syntaxString
        case .number: return .syntaxNumber
        case .literal: return .syntaxNull
        case .serialized: return .syntaxType
        case .reference: return .syntaxComment
        case .container: return .editorText
        case .muted: return .editorLineNumber
        }
    }

    @MainActor var color: NSColor {
        ThemeEngine.shared.palette[slot]
    }
}

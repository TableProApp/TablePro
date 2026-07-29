//
//  SQLSnippetMarker.swift
//  TablePro
//
//  Cursor-placement marker for SQL favorite keyword expansion. The first
//  ";;" in a favorite's query marks where the caret lands after the keyword
//  expands; the marker is stripped from the inserted text. Offsets are
//  UTF-16 units so the caret resolves correctly after multibyte text.
//

import Foundation

enum SQLSnippetMarker {
    static let token = ";;"

    struct Expansion {
        let text: String
        let cursorOffset: Int
    }

    static func expand(_ raw: String) -> Expansion? {
        let mutable = NSMutableString(string: raw)
        let markerRange = mutable.range(of: token)
        guard markerRange.location != NSNotFound else { return nil }
        mutable.deleteCharacters(in: markerRange)
        return Expansion(text: mutable as String, cursorOffset: markerRange.location)
    }
}

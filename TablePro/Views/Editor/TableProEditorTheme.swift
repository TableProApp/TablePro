//
//  TableProEditorTheme.swift
//  TablePro
//
//  Adapts ThemeEngine colors to TableProEditorKit's EditorTheme.
//

import AppKit
import TableProEditorKit

/// Maps ThemeEngine's active theme to TableProEditorKit's EditorTheme
struct TableProEditorTheme {
    @MainActor
    static func make() -> EditorTheme {
        ThemeEngine.shared.makeEditorTheme()
    }
}

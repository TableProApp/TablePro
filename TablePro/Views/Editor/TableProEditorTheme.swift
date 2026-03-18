//
//  TableProEditorTheme.swift
//  TablePro
//
//  Adapts ThemeEngine colors to CodeEditSourceEditor's EditorTheme.
//

import AppKit
import CodeEditSourceEditor

/// Maps ThemeEngine's active theme to CodeEditSourceEditor's EditorTheme
struct TableProEditorTheme {
    @MainActor
    static func make() -> EditorTheme {
        ThemeEngine.shared.makeEditorTheme()
    }
}

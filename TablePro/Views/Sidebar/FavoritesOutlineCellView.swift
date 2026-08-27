//
//  FavoritesOutlineCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// One row of the Favorites list. Only folders are renamed here, so the editor keeps one glyph.
internal final class FavoritesOutlineCellView<Row: View>: RenamableSidebarCellView<Row> {
    override internal var editorSymbolName: String { "folder" }
    override internal var editorAccessibilityIdentifier: String { "favorites-rename-field" }
}

//
//  DataGridCellRegistry.swift
//  TablePro
//

import AppKit

@MainActor
final class DataGridCellRegistry {
    private(set) var nullDisplayString: String
    private(set) var showsInvisibleCharacters: Bool
    private(set) var palette: DataGridCellPalette
    private(set) var scope: ThemeScope
    private var paletteKey: PaletteKey

    private struct PaletteKey: Equatable {
        let revision: Int
        let generation: Int
        let appearance: NSAppearance.Name
    }

    init(scope: ThemeScope = .live) {
        self.scope = scope
        let settings = AppSettingsManager.shared.dataGrid
        nullDisplayString = settings.nullDisplay
        showsInvisibleCharacters = settings.showInvisibleCharacters
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        paletteKey = Self.paletteKey(for: appearance)
        palette = scope.dataGridCellPalette(in: appearance)
    }

    func reloadSettings(_ settings: DataGridSettings = AppSettingsManager.shared.dataGrid) {
        nullDisplayString = settings.nullDisplay
        showsInvisibleCharacters = settings.showInvisibleCharacters
    }

    // Asked by every row as it draws: the tints resolve in the appearance the row draws in, which only the draw knows.
    func preparePalette(in appearance: NSAppearance) {
        let key = Self.paletteKey(for: appearance)
        guard key != paletteKey else { return }
        paletteKey = key
        palette = scope.dataGridCellPalette(in: appearance)
    }

    // A fixed scope never moves the key, so a new one rebuilds the palette here.
    func adopt(_ scope: ThemeScope, in appearance: NSAppearance) {
        self.scope = scope
        paletteKey = Self.paletteKey(for: appearance)
        palette = scope.dataGridCellPalette(in: appearance)
    }

    private static func paletteKey(for appearance: NSAppearance) -> PaletteKey {
        let change = ThemeEngine.shared.change
        return PaletteKey(revision: change.revision, generation: change.generation, appearance: appearance.name)
    }
}

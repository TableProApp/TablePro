//
//  DataGridCellTextGeometry.swift
//  TablePro
//
//  The one owner of where a cell's glyphs sit, shared by the CoreText draw path and the
//  overlay editor so the two cannot disagree. Before it existed each side had its own
//  numbers and an inline edit visibly shifted the value it was editing.
//

import AppKit

@MainActor
enum DataGridCellTextGeometry {
    /// Baseline questions go through a detached layout manager, never a text view's
    /// `layoutManager` property: one read of that property downgrades a TextKit 2 view to
    /// TextKit 1, which reverts the overlay's no-wrap layout fix (#2381). Measured: the
    /// detached answer equals the TextKit 2 first-fragment glyph origin.
    private static let baselineMeasurer = NSLayoutManager()

    /// The centered baseline the renderer draws at, floored to a whole point because that
    /// is where TextKit puts it: measured at 1x and 2x backing, TextKit floors a rendered
    /// baseline to integral points while `CTLineDraw` honors fractions. Flooring the shared
    /// target is what lets the editor land on the drawn glyphs exactly at every scale.
    static func baselineY(rowHeight: CGFloat, font: NSFont) -> CGFloat {
        ((rowHeight - font.ascender + font.descender - font.leading) / 2 + font.ascender)
            .rounded(.down)
    }

    /// The symmetric `textContainerInset.height` that puts an overlay text view's first
    /// baseline on `baselineY`. Negative when the font outgrows the row; AppKit accepts a
    /// negative inset and parity holds.
    static func textContainerTopInset(rowHeight: CGFloat, font: NSFont) -> CGFloat {
        baselineY(rowHeight: rowHeight, font: font) - baselineMeasurer.defaultBaselineOffset(for: font)
    }

    static func lineHeight(for font: NSFont) -> CGFloat {
        baselineMeasurer.defaultLineHeight(for: font)
    }
}

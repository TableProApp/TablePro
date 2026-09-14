//
//  ConnectionIconMetrics.swift
//  TablePro
//

import Foundation

/// How big a database icon is drawn, stated once.
///
/// The size used to be typed at each call site, and eight sites had drifted to five numbers: the
/// same connection was 18pt in the welcome list, 28pt in the import sheet beside it, 16pt in the
/// form that opened from it, and 26pt in the chooser that opened from that. A list reads worst when
/// the icon changes size depending on which list it is.
internal enum ConnectionIconMetrics {
    /// A row in a list or in the connection tree, sized to the row's own text. Navicat, DataGrip
    /// and Sequel Ace all draw one at about this size, which is what keeps a long list scannable.
    internal static let row: CGFloat = 15

    /// The type chooser, where the icon is the thing being picked rather than a label on something
    /// else.
    internal static let chooser: CGFloat = 22

    /// A pane with nothing else in it.
    internal static let hero: CGFloat = 40

    /// An SF Symbol is sized by its font rather than by its frame, and a glyph given the frame's
    /// full height overflows it: a point size names the font's em, not the drawn glyph. The asset
    /// icons are `resizable` and take the frame directly, so only the symbols need this.
    internal static func symbolPoints(_ points: CGFloat) -> CGFloat {
        points * 0.86
    }
}

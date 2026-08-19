//
//  EditorPeripherals.swift
//  TablePro
//

import CodeEditSourceEditor

/// Builds the gutter and rail settings every code editor in the app shares.
///
/// The rule this exists to hold is that a gutter always carries line numbers. The gutter can technically be shown
/// without them so it can host the fold rail on its own, and doing that reserves a 30pt column to hold a 14pt
/// control: two of its paddings only exist to separate line numbers from the code, so a gutter with no numbers is
/// charged for a separation that is not there. Worse, a document with nothing foldable leaves that column blank,
/// which reads as text that failed to line up rather than as a gutter. Every editor here therefore shows a gutter
/// only when it shows numbers, and no editor sets the two apart.
enum EditorPeripherals {
    /// - Parameters:
    ///   - lineNumbers: Whether to number the lines. Also decides whether there is a gutter at all.
    ///   - folding: Whether folds are calculated. The chevrons only appear when there is a gutter to draw them in,
    ///              but folds stay available through the Query menu and the collapsed chips either way.
    ///   - minimap: Whether to show the minimap.
    static func make(
        lineNumbers: Bool,
        folding: Bool,
        minimap: Bool = false
    ) -> SourceEditorConfiguration.Peripherals {
        .init(
            showGutter: lineNumbers,
            showLineNumbers: lineNumbers,
            showMinimap: minimap,
            showFoldingRibbon: folding
        )
    }

    /// The settings for a read-only preview, which numbers its lines only when folding gives the gutter a reason to
    /// be there.
    static func preview(folding: Bool) -> SourceEditorConfiguration.Peripherals {
        make(lineNumbers: folding, folding: folding)
    }
}

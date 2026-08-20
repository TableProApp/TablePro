//
//  EditorPeripherals.swift
//  TablePro
//

import CodeEditSourceEditor

/// Builds the gutter and rail settings every code editor in the app shares.
///
/// Two rules live here because seven call sites each had to remember them and three had stopped.
///
/// A gutter always carries line numbers. It can technically be shown without them so it can host the fold rail on
/// its own, and doing that reserves a 30pt column to hold a 14pt control: two of its paddings only exist to separate
/// line numbers from the code, so a gutter with no numbers is charged for a separation that is not there. Worse, a
/// document with nothing foldable leaves that column blank, which reads as text that failed to line up.
///
/// A gutter that is not running down the side of a window measures itself against its document. The editor's gutter
/// keeps a window margin and reserves room for three digits so it does not resize under the reader's hands as a
/// document passes nine and ninety-nine lines. An inline listing has no window edge and a line count that will not
/// change, and paying for both put 35pt of nothing to the left of a single-digit line number.
enum EditorPeripherals {
    /// The settings for the editor a reader works in.
    /// - Parameters:
    ///   - lineNumbers: Whether to number the lines. Also decides whether there is a gutter at all.
    ///   - folding: Whether folds are calculated. The chevrons only appear when there is a gutter to draw them in,
    ///              but folds stay available through the Query menu and the collapsed chips either way.
    ///   - statementRunControls: Whether to offer a run control beside each statement. Only the editor a reader works
    ///                            in can run anything, so a listing or a preview never asks for them.
    static func editor(
        lineNumbers: Bool,
        folding: Bool,
        statementRunControls: Bool = false
    ) -> SourceEditorConfiguration.Peripherals {
        make(
            lineNumbers: lineNumbers,
            folding: folding,
            fitsContent: false,
            statementRunControls: statementRunControls
        )
    }

    /// The settings for a listing embedded in another view, which sizes its gutter to the lines it was handed.
    static func inline(lineNumbers: Bool, folding: Bool) -> SourceEditorConfiguration.Peripherals {
        make(lineNumbers: lineNumbers, folding: folding, fitsContent: true)
    }

    /// The settings for a read-only preview, which numbers its lines only when folding gives the gutter a reason to
    /// be there.
    static func preview(folding: Bool) -> SourceEditorConfiguration.Peripherals {
        inline(lineNumbers: folding, folding: folding)
    }

    private static func make(
        lineNumbers: Bool,
        folding: Bool,
        fitsContent: Bool,
        statementRunControls: Bool = false
    ) -> SourceEditorConfiguration.Peripherals {
        .init(
            showGutter: lineNumbers,
            showLineNumbers: lineNumbers,
            showMinimap: false,
            showFoldingRibbon: folding,
            showStatementRunControls: lineNumbers && statementRunControls,
            gutterFitsContent: fitsContent
        )
    }
}

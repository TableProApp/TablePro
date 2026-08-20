//
//  EditorConfig+Peripherals.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/16/25.
//

extension SourceEditorConfiguration {
    public struct Peripherals: Equatable {
        /// Whether to show the gutter.
        public var showGutter: Bool = true

        /// Whether to draw line numbers in the gutter. The gutter can stay visible without them, which lets an editor
        /// show the folding ribbon while hiding line numbers.
        public var showLineNumbers: Bool = true

        /// Whether to show the minimap.
        public var showMinimap: Bool

        /// Whether to show the reformatting guide.
        public var showReformattingGuide: Bool

        /// Whether to show the folding ribbon. Only available if ``showGutter`` is `true`.
        public var showFoldingRibbon: Bool

        /// Whether to show a run control beside each statement. Only available if ``showGutter`` is `true`.
        ///
        /// Off by default, because only an editor whose host can run part of a document has anything to put here.
        public var showStatementRunControls: Bool = false

        /// Whether the gutter measures itself against the document rather than against a full editor window.
        ///
        /// See ``GutterView/fitsContent``. Set this for a short listing embedded in another view, which has no window
        /// edge to keep a margin from and a line count that is not going to grow.
        public var gutterFitsContent: Bool = false

        /// The largest document, in UTF-16 units, that folds are calculated for. Fold calculation walks every line in
        /// the document, so past this length the editor stops computing folds instead of blocking on a document it
        /// cannot fold responsively.
        public var foldingSizeLimit: Int = EditorHighlighting.maxHighlightableCharacters

        /// Configuration for drawing invisible characters.
        ///
        /// See ``InvisibleCharactersConfiguration`` for more details.
        public var invisibleCharactersConfiguration: InvisibleCharactersConfiguration

        /// Indicates characters that the user may not have meant to insert, such as a zero-width space: `(0x200D)` or a
        /// non-standard quote character: `“ (0x201C)`.
        public var warningCharacters: Set<UInt16>

        public init(
            showGutter: Bool = true,
            showLineNumbers: Bool = true,
            showMinimap: Bool = true,
            showReformattingGuide: Bool = false,
            showFoldingRibbon: Bool = true,
            showStatementRunControls: Bool = false,
            gutterFitsContent: Bool = false,
            foldingSizeLimit: Int = EditorHighlighting.maxHighlightableCharacters,
            invisibleCharactersConfiguration: InvisibleCharactersConfiguration = .empty,
            warningCharacters: Set<UInt16> = []
        ) {
            self.showGutter = showGutter
            self.showLineNumbers = showLineNumbers
            self.showMinimap = showMinimap
            self.showReformattingGuide = showReformattingGuide
            self.showFoldingRibbon = showFoldingRibbon
            self.showStatementRunControls = showStatementRunControls
            self.gutterFitsContent = gutterFitsContent
            self.foldingSizeLimit = foldingSizeLimit
            self.invisibleCharactersConfiguration = invisibleCharactersConfiguration
            self.warningCharacters = warningCharacters
        }

        @MainActor
        func didSetOnController(controller: TextViewController, oldConfig: Peripherals?) {
            var shouldUpdateInsets = false

            if oldConfig?.showGutter != showGutter {
                controller.gutterView.isHidden = !showGutter
                shouldUpdateInsets = true
            }

            if oldConfig?.showMinimap != showMinimap {
                controller.minimapView?.isHidden = !showMinimap
                shouldUpdateInsets = true
            }

            if oldConfig?.showReformattingGuide != showReformattingGuide {
                controller.reformattingGuideView.isHidden = !showReformattingGuide
                controller.reformattingGuideView.updatePosition(in: controller)
            }

            if oldConfig?.showLineNumbers != showLineNumbers {
                controller.gutterView.showLineNumbers = showLineNumbers
                shouldUpdateInsets = true
            }

            if oldConfig?.showFoldingRibbon != showFoldingRibbon {
                controller.gutterView.showFoldingRibbon = showFoldingRibbon
            }

            if oldConfig?.showStatementRunControls != showStatementRunControls {
                controller.gutterView.showStatementRunControls = showStatementRunControls
                shouldUpdateInsets = true
            }

            if oldConfig?.gutterFitsContent != gutterFitsContent {
                controller.gutterView.fitsContent = gutterFitsContent
            }

            if oldConfig?.invisibleCharactersConfiguration != invisibleCharactersConfiguration {
                controller.invisibleCharactersCoordinator.configuration = invisibleCharactersConfiguration
            }

            if oldConfig?.warningCharacters != warningCharacters {
                controller.invisibleCharactersCoordinator.warningCharacters = warningCharacters
            }

            if shouldUpdateInsets && controller.scrollView != nil { // Check for view existence
                controller.updateContentInsets()
                controller.updateTextInsets()
            }
        }
    }
}

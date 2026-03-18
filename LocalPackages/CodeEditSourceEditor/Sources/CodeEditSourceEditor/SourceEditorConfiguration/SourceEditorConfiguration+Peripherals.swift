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

        /// Whether to show the minimap.
        public var showMinimap: Bool

        /// Whether to show the reformatting guide.
        public var showReformattingGuide: Bool

        /// Whether to show the folding ribbon. Only available if ``showGutter`` is `true`.
        public var showFoldingRibbon: Bool

        /// Configuration for drawing invisible characters.
        ///
        /// See ``InvisibleCharactersConfiguration`` for more details.
        public var invisibleCharactersConfiguration: InvisibleCharactersConfiguration

        /// Indicates characters that the user may not have meant to insert, such as a zero-width space: `(0x200D)` or a
        /// non-standard quote character: `“ (0x201C)`.
        public var warningCharacters: Set<UInt16>

        public init(
            showGutter: Bool = true,
            showMinimap: Bool = true,
            showReformattingGuide: Bool = false,
            showFoldingRibbon: Bool = true,
            invisibleCharactersConfiguration: InvisibleCharactersConfiguration = .empty,
            warningCharacters: Set<UInt16> = []
        ) {
            self.showGutter = showGutter
            self.showMinimap = showMinimap
            self.showReformattingGuide = showReformattingGuide
            self.showFoldingRibbon = showFoldingRibbon
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

            if oldConfig?.showFoldingRibbon != showFoldingRibbon {
                controller.gutterView.showFoldingRibbon = showFoldingRibbon
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

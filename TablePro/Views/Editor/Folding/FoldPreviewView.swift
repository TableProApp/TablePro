//
//  FoldPreviewView.swift
//  TablePro
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

/// The block behind a collapsed fold, shown while the pointer rests on its placeholder.
///
/// The block is rendered by a read-only editor rather than a label. The text storage only carries highlighting for
/// ranges the highlighter has laid out, and a collapsed fold is by definition not laid out, so reading its attributes
/// back yields plain text. An editor runs the same tree-sitter grammar and the same theme over the block, so the peek
/// matches the code it stands for. It is neither editable nor selectable, so peeking never moves the caret.
///
/// The peek draws its own surface. A popover over a light editor renders pure white with no border and no shadow, so
/// content that simply fills it reads as stray text drawn over the code rather than as a panel floating above it. The
/// code keeps the theme's editor background so its colours stay legible, and a hairline marks where the panel ends.
struct FoldPreviewView: View {
    let layout: FoldPreviewMetrics.Layout
    let language: CodeLanguage

    @State private var text: String
    @State private var editorState = SourceEditorState()

    init(layout: FoldPreviewMetrics.Layout, language: CodeLanguage) {
        self.layout = layout
        self.language = language
        _text = State(initialValue: layout.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SourceEditor(
                $text,
                language: language,
                configuration: Self.configuration,
                state: $editorState
            )
            .frame(width: layout.size.width, height: layout.size.height)

            if layout.hiddenLineCount > 0 {
                Divider()

                Text(String(format: String(localized: "%d more lines"), layout.hiddenLineCount))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
        .background(ThemeEngine.shared.colors.editor.backgroundSwiftUI)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .padding(Self.surfaceInset)
    }

    /// Matches the radius AppKit gives a popover, so the peek reads as the panel rather than as something inside it.
    private static let cornerRadius: CGFloat = 6

    /// Room for the panel's own edge inside the popover's content area.
    static let surfaceInset: CGFloat = 1

    private static var configuration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                useThemeBackground: false,
                font: ThemeEngine.shared.editorFonts.font,
                wrapLines: false
            ),
            behavior: .init(
                isEditable: false,
                isSelectable: false
            ),
            layout: .init(
                contentInsets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            ),
            peripherals: EditorPeripherals.inline(lineNumbers: false, folding: false)
        )
    }
}

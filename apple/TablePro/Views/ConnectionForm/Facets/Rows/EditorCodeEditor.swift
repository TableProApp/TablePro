//
//  EditorCodeEditor.swift
//  TablePro
//

import AppKit
import SwiftUI

enum EditorCodeLanguage {
    case sql
    case shell
    case plain
    case json
}

// A multi-line editor that is a Section of its own: the header names it. It grows with its lines from minHeight, and
// Tab leaves it as in any form field. Escape in it never cancels the window: the window controller ends the edit.
struct EditorCodeEditor: View {
    @Binding private var text: String
    private let language: EditorCodeLanguage
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore
    private let minHeight: CGFloat

    private static let maxHeight: CGFloat = 320
    private static let wellShape = RoundedRectangle(cornerRadius: 6)

    init(
        text: Binding<String>,
        language: EditorCodeLanguage,
        row: EditorRow,
        store: ConnectionEditorStore,
        minHeight: CGFloat = 96
    ) {
        _text = text
        self.language = language
        self.row = row
        self.store = store
        self.minHeight = minHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            editor
                .frame(height: height)
                .editorRowFocus(row, store: store)

            EditorRowIssueNotice(row: row, store: store)
        }
    }

    // The card is the only frame: prose sits on it, code sits in a well like CodeWell, on the editor's colors.
    @ViewBuilder
    private var editor: some View {
        let field = TextValueEditor(
            text: store.tracking($text, row: row),
            font: font,
            borderType: .noBorder,
            movesFocusOnTab: true,
            style: language == .plain ? .plain : .code,
            drawsBackground: language != .plain
        )
        .accessibilityIdentifier(row.accessibilityIdentifier)
        if language == .plain {
            field
        } else {
            field
                .clipShape(Self.wellShape)
                .overlay(Self.wellShape.stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }

    private var font: NSFont {
        let size = NSFont.systemFontSize
        return language == .plain
            ? .systemFont(ofSize: size)
            : .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // Hard line breaks only: a wrapped long line scrolls inside the editor rather than growing it.
    private var height: CGFloat {
        let lines = CGFloat(text.reduce(into: 1) { count, character in
            if character.isNewline { count += 1 }
        })
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let chrome: CGFloat = 16
        let content = lines * lineHeight + chrome
        return min(max(content, minHeight), max(minHeight, Self.maxHeight))
    }
}

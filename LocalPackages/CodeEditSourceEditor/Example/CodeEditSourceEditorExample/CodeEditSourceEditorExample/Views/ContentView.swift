//
//  ContentView.swift
//  CodeEditSourceEditorExample
//
//  Created by Khan Winter on 2/24/24.
//

import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView

struct ContentView: View {
    @Environment(\.colorScheme)
    var colorScheme

    @Binding var document: CodeEditSourceEditorExampleDocument
    let fileURL: URL?

    @State private var language: CodeLanguage = .default
    @State private var theme: EditorTheme = .light
    @State private var editorState = SourceEditorState(
        cursorPositions: [CursorPosition(line: 1, column: 1)]
    )
    @StateObject private var suggestions: MockCompletionDelegate = MockCompletionDelegate()
    @StateObject private var jumpToDefinition: MockJumpToDefinitionDelegate = MockJumpToDefinitionDelegate()

    @State private var font: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    @AppStorage("wrapLines") private var wrapLines: Bool = true
    @AppStorage("systemCursor") private var useSystemCursor: Bool = false

    @State private var indentOption: IndentOption = .spaces(count: 4)
    @AppStorage("reformatAtColumn") private var reformatAtColumn: Int = 80

    @AppStorage("showGutter") private var showGutter: Bool = true
    @AppStorage("showMinimap") private var showMinimap: Bool = true
    @AppStorage("showReformattingGuide") private var showReformattingGuide: Bool = false
    @AppStorage("showFoldingRibbon") private var showFoldingRibbon: Bool = true
    @State private var invisibleCharactersConfig: InvisibleCharactersConfiguration = .empty
    @State private var warningCharacters: Set<UInt16> = []

    @State private var isInLongParse = false
    @State private var settingsIsPresented: Bool = false

    @State private var treeSitterClient = TreeSitterClient()

    private func contentInsets(proxy: GeometryProxy) -> NSEdgeInsets {
        NSEdgeInsets(top: proxy.safeAreaInsets.top, left: showGutter ? 0 : 1, bottom: 28.0, right: 0)
    }

    init(document: Binding<CodeEditSourceEditorExampleDocument>, fileURL: URL?) {
        self._document = document
        self.fileURL = fileURL
    }

    var body: some View {
        GeometryReader { proxy in
            SourceEditor(
                document.text,
                language: language,
                configuration: SourceEditorConfiguration(
                    appearance: .init(theme: theme, font: font, wrapLines: wrapLines),
                    behavior: .init(
                        indentOption: indentOption,
                        reformatAtColumn: reformatAtColumn
                    ),
                    layout: .init(contentInsets: contentInsets(proxy: proxy)),
                    peripherals: .init(
                        showGutter: showGutter,
                        showMinimap: showMinimap,
                        showReformattingGuide: showReformattingGuide,
                        invisibleCharactersConfiguration: invisibleCharactersConfig,
                        warningCharacters: warningCharacters
                    )
                ),
                state: $editorState,
                completionDelegate: suggestions,
                jumpToDefinitionDelegate: jumpToDefinition
            )
            .overlay(alignment: .bottom) {
                StatusBar(
                    fileURL: fileURL,
                    document: $document,
                    wrapLines: $wrapLines,
                    useSystemCursor: $useSystemCursor,
                    state: $editorState,
                    isInLongParse: $isInLongParse,
                    language: $language,
                    theme: $theme,
                    showGutter: $showGutter,
                    showMinimap: $showMinimap,
                    indentOption: $indentOption,
                    reformatAtColumn: $reformatAtColumn,
                    showReformattingGuide: $showReformattingGuide,
                    showFoldingRibbon: $showFoldingRibbon,
                    invisibles: $invisibleCharactersConfig,
                    warningCharacters: $warningCharacters
                )
            }
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: TreeSitterClient.Constants.longParse)) { _ in
                withAnimation(.easeIn(duration: 0.1)) {
                    isInLongParse = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: TreeSitterClient.Constants.longParseFinished)) { _ in
                withAnimation(.easeIn(duration: 0.1)) {
                    isInLongParse = false
                }
            }
            .onChange(of: colorScheme) { _, newValue in
                if newValue == .dark {
                    theme = .dark
                } else {
                    theme = .light
                }
            }
        }
    }
}

#Preview {
    ContentView(document: .constant(CodeEditSourceEditorExampleDocument()), fileURL: nil)
}

//
//  JSONViewerView.swift
//  TablePro
//

import SwiftUI

internal enum JSONTreeDocument {
    case emptyValue
    case tree(JSONTreeNode)
    case unavailable(JSONTreeParseError)

    /// A blank value holds nothing, which is not broken JSON, so it never reaches the parser. The
    /// cap comes first because the blank check reads every character.
    init(displayText: String) {
        let document = JsonReindenter.normalize(displayText)
        guard JSONTreeParser.fitsSizeCap(document) else {
            self = .unavailable(.tooLarge)
            return
        }
        if document.unicodeScalars.allSatisfy(\.properties.isWhitespace) {
            self = .emptyValue
            return
        }
        switch JSONTreeParser.parse(document) {
        case .success(let root):
            self = .tree(root)
        case .failure(let error):
            self = .unavailable(error)
        }
    }

    /// The size cap counts the document, not the indentation a viewer added to show it.
    static func parse(_ displayText: String) -> Result<JSONTreeNode, JSONTreeParseError> {
        JSONTreeParser.parse(JsonReindenter.normalize(displayText))
    }
}

internal struct JSONViewerView: View {
    private struct ParsedTree {
        let source: String
        let document: JSONTreeDocument
    }

    @Binding var text: String
    let isEditable: Bool
    var onDismiss: (() -> Void)?
    var onCommit: ((String) -> Void)?
    var onPopOut: ((String) -> Void)?

    @State private var viewMode: JSONViewMode
    @State private var treeSearchText = ""
    @State private var parsedTree: ParsedTree?
    @State private var displayText: String
    @State private var showInvalidAlert = false

    init(
        text: Binding<String>,
        isEditable: Bool,
        onDismiss: (() -> Void)? = nil,
        onCommit: ((String) -> Void)? = nil,
        onPopOut: ((String) -> Void)? = nil,
        initialViewMode: JSONViewMode? = nil
    ) {
        self._text = text
        self.isEditable = isEditable
        self.onDismiss = onDismiss
        self.onCommit = onCommit
        self.onPopOut = onPopOut
        self._displayText = State(wrappedValue: JsonReindenter.reindent(text.wrappedValue))
        self._viewMode = State(
            initialValue: initialViewMode ?? AppSettingsManager.shared.editor.jsonViewerPreferredMode
        )
    }

    private var isLiveBinding: Bool {
        isEditable && onCommit == nil
    }

    /// The tree is parsed only while it is on screen, so typing in Text mode never pays for it.
    /// Entering Tree mode parses in the same update that shows it, or the last tree would draw first.
    private var viewModeSelection: Binding<JSONViewMode> {
        Binding(
            get: { viewMode },
            set: { mode in
                if mode == .tree { parseTree(from: displayText) }
                viewMode = mode
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            viewerToolbar
            Divider()
            viewerContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isEditable, onCommit != nil, onDismiss != nil {
                Divider()
                editorFooter
            }
        }
        .onAppear { initializeView() }
        .onChange(of: text) { _ in syncFromExternal() }
        .onChange(of: displayText) { _ in handleDisplayTextChange() }
        .onChange(of: viewMode) { _ in
            AppSettingsManager.shared.editor.jsonViewerPreferredMode = viewMode
        }
        .alert("Invalid JSON", isPresented: $showInvalidAlert) {
            Button(String(localized: "Save Anyway")) { commitAndClose(displayText) }
            Button(String(localized: "Cancel"), role: .cancel) { }
        } message: {
            Text("The text is not valid JSON. Save anyway?")
        }
    }

    // MARK: - Toolbar

    private var viewerToolbar: some View {
        HStack(spacing: 8) {
            Picker("View Mode", selection: viewModeSelection) {
                Text("Text").tag(JSONViewMode.text)
                Text("Tree").tag(JSONViewMode.tree)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if let onPopOut {
                Button { onPopOut(displayText) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Open in Window"))
                .accessibilityLabel(String(localized: "Open in Window"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var viewerContent: some View {
        switch viewMode {
        case .text:
            JSONCodeEditor(text: $displayText, isEditable: isEditable)
        case .tree:
            switch parsedTree?.document {
            case .emptyValue?:
                emptyValueView
            case .tree(let tree)?:
                JSONTreeView(rootNode: tree, searchText: $treeSearchText)
            case .unavailable(let error)?:
                treeErrorView(error)
            case nil:
                Color.clear
            }
        }
    }

    private var emptyValueView: some View {
        UnavailableStateView {
            Label(String(localized: "Empty Value"), systemImage: "curlybraces")
        } description: {
            if isEditable {
                Text(String(localized: "Use text mode to enter JSON."))
            }
        }
    }

    private func treeErrorView(_ error: JSONTreeParseError) -> some View {
        UnavailableStateView {
            Label(
                error == .tooLarge
                    ? String(localized: "JSON Too Large")
                    : String(localized: "Invalid JSON"),
                systemImage: error == .tooLarge ? "doc.text" : "exclamationmark.triangle"
            )
        } description: {
            Text(
                error == .tooLarge
                    ? String(localized: "This JSON document is too large for tree view. Use text mode instead.")
                    : String(localized: "The text could not be parsed as JSON. Use text mode to view or edit.")
            )
        }
    }

    // MARK: - Footer

    private var editorFooter: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) { onDismiss?() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Save")) { saveJSON() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Logic

    private func initializeView() {
        let pretty = JsonReindenter.reindent(text)
        displayText = pretty
        if viewMode == .tree { parseTree(from: pretty) }
    }

    private func syncFromExternal() {
        guard JsonReindenter.normalize(text) != JsonReindenter.normalize(displayText) else { return }
        displayText = JsonReindenter.reindent(text)
    }

    private func handleDisplayTextChange() {
        if viewMode == .tree { parseTree(from: displayText) }
        guard isLiveBinding,
              JsonReindenter.normalize(displayText) != JsonReindenter.normalize(text) else { return }
        text = displayText
    }

    /// A pane that is added back runs `onAppear` again over the same text. Parsing it a second time
    /// would hand the tree a new root, which drops its selection.
    private func parseTree(from displayText: String) {
        guard parsedTree?.source != displayText else { return }
        parsedTree = ParsedTree(source: displayText, document: JSONTreeDocument(displayText: displayText))
    }

    private func saveJSON() {
        guard !displayText.isEmpty else {
            commitAndClose("")
            return
        }
        guard JsonSyntaxParser.parse(displayText) != nil else {
            showInvalidAlert = true
            return
        }
        commitAndClose(displayText)
    }

    private func commitAndClose(_ value: String) {
        onCommit?(JsonReindenter.normalize(value))
        onDismiss?()
    }
}

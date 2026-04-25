//
//  JSONViewerView.swift
//  TablePro
//

import SwiftUI

internal struct JSONViewerView: View {
    @Binding var text: String
    let isEditable: Bool
    var onDismiss: (() -> Void)?
    var onCommit: ((String) -> Void)?
    var onPopOut: ((String) -> Void)?

    @State private var viewMode: JSONViewMode
    @State private var treeSearchText = ""
    @State private var parsedTree: JSONTreeNode?
    @State private var parseError: JSONTreeParseError?
    @State private var prettyText = ""
    @State private var showInvalidAlert = false

    init(
        text: Binding<String>,
        isEditable: Bool,
        onDismiss: (() -> Void)? = nil,
        onCommit: ((String) -> Void)? = nil,
        onPopOut: ((String) -> Void)? = nil
    ) {
        self._text = text
        self.isEditable = isEditable
        self.onDismiss = onDismiss
        self.onCommit = onCommit
        self.onPopOut = onPopOut
        self._viewMode = State(initialValue: AppSettingsManager.shared.editor.jsonViewerPreferredMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            viewerToolbar
            Divider()
            viewerContent
            if isEditable, onCommit != nil, onDismiss != nil {
                Divider()
                editorFooter
            }
        }
        .onAppear { initializeView() }
        .onChange(of: text) { reparseIfNeeded() }
        .onChange(of: viewMode) {
            AppSettingsManager.shared.editor.jsonViewerPreferredMode = viewMode
        }
        .alert("Invalid JSON", isPresented: $showInvalidAlert) {
            Button(String(localized: "Save Anyway")) { commitAndClose(text) }
            Button(String(localized: "Cancel"), role: .cancel) { }
        } message: {
            Text("The text is not valid JSON. Save anyway?")
        }
    }

    // MARK: - Toolbar

    private var viewerToolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $viewMode) {
                Text("Text").tag(JSONViewMode.text)
                Text("Tree").tag(JSONViewMode.tree)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            if let onPopOut {
                Button { onPopOut(text) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Open in Window"))
            }
            if viewMode == .text && isEditable {
                Button {
                    if let formatted = text.prettyPrintedAsJson() {
                        text = formatted
                    }
                } label: {
                    Image(systemName: "curlybraces")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Format JSON"))
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
            JSONSyntaxTextView(
                text: isEditable ? $text : $prettyText,
                isEditable: isEditable,
                wordWrap: true
            )
        case .tree:
            if let tree = parsedTree {
                JSONTreeView(rootNode: tree, searchText: $treeSearchText)
            } else if let error = parseError {
                treeErrorView(error)
            } else {
                treeErrorView(.invalidJSON)
            }
        }
    }

    private func treeErrorView(_ error: JSONTreeParseError) -> some View {
        ContentUnavailableView {
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
        prettyText = text.prettyPrintedAsJson() ?? text
        parseTree()
    }

    private func reparseIfNeeded() {
        if !isEditable {
            prettyText = text.prettyPrintedAsJson() ?? text
        }
        parseTree()
    }

    private func parseTree() {
        switch JSONTreeParser.parse(text) {
        case .success(let tree):
            parsedTree = tree
            parseError = nil
        case .failure(let error):
            parsedTree = nil
            parseError = error
        }
    }

    private func saveJSON() {
        guard !text.isEmpty else {
            commitAndClose(text)
            return
        }
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            showInvalidAlert = true
            return
        }
        commitAndClose(text)
    }

    private func commitAndClose(_ value: String) {
        let saveValue = Self.compact(value) ?? value
        onCommit?(saveValue)
        onDismiss?()
    }

    static func compact(_ jsonString: String?) -> String? {
        guard let data = jsonString?.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let compactData = try? JSONSerialization.data(
                  withJSONObject: jsonObject,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let compactString = String(data: compactData, encoding: .utf8) else {
            return nil
        }
        return compactString
    }
}

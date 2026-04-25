//
//  ResultsJsonView.swift
//  TablePro
//

import SwiftUI

internal struct ResultsJsonView: View {
    let columns: [String]
    let columnTypes: [ColumnType]
    let rows: [[String?]]
    let selectedRowIndices: Set<Int>

    @State private var viewMode: JSONViewMode
    @State private var treeSearchText = ""
    @State private var parsedTree: JSONTreeNode?
    @State private var parseError: JSONTreeParseError?
    @State private var prettyText = ""
    @State private var cachedJson = ""
    @State private var copied = false

    init(
        columns: [String],
        columnTypes: [ColumnType],
        rows: [[String?]],
        selectedRowIndices: Set<Int>
    ) {
        self.columns = columns
        self.columnTypes = columnTypes
        self.rows = rows
        self.selectedRowIndices = selectedRowIndices
        self._viewMode = State(initialValue: AppSettingsManager.shared.editor.jsonViewerPreferredMode)
    }

    private var displayRows: [[String?]] {
        if selectedRowIndices.isEmpty {
            return rows
        }
        return selectedRowIndices.sorted().compactMap { idx in
            rows.indices.contains(idx) ? rows[idx] : nil
        }
    }

    private var rowCountText: String {
        let displaying = displayRows.count
        let total = rows.count
        if selectedRowIndices.isEmpty || displaying == total {
            return String(format: String(localized: "%d rows"), total)
        }
        return String(format: String(localized: "%d of %d rows"), displaying, total)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { rebuildJson() }
        .onChange(of: selectedRowIndices) { rebuildJson() }
        .onChange(of: rows.count) { rebuildJson() }
        .onChange(of: viewMode) {
            AppSettingsManager.shared.editor.jsonViewerPreferredMode = viewMode
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(rowCountText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Picker("", selection: $viewMode) {
                Text("Text").tag(JSONViewMode.text)
                Text("Tree").tag(JSONViewMode.tree)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer()

            Button {
                ClipboardService.shared.writeText(cachedJson)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Label(
                    copied ? String(localized: "Copied!") : String(localized: "Copy JSON"),
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                String(localized: "No Data"),
                systemImage: "curlybraces",
                description: Text(String(localized: "Execute a query to view results as JSON"))
            )
        } else {
            switch viewMode {
            case .text:
                JSONSyntaxTextView(
                    text: $prettyText,
                    isEditable: false,
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
                    : String(localized: "The text could not be parsed as JSON.")
            )
        }
    }

    // MARK: - JSON Generation

    private func rebuildJson() {
        let converter = JsonRowConverter(columns: columns, columnTypes: columnTypes)
        let json = converter.generateJson(rows: displayRows)
        cachedJson = json
        prettyText = json.prettyPrintedAsJson() ?? json

        let result = JSONTreeParser.parse(json)
        switch result {
        case .success(let node):
            parsedTree = node
            parseError = nil
        case .failure(let error):
            parsedTree = nil
            parseError = error
        }
    }
}

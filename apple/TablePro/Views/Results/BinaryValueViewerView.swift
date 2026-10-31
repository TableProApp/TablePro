//
//  BinaryValueViewerView.swift
//  TablePro
//

import SwiftUI
import TableProTheme

internal enum BinaryValueViewMode: Hashable {
    case tree
    case text
    case hex
}

internal struct BinaryValueViewerView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    let data: Data
    let format: BinaryValueFormat
    var onPopOut: (() -> Void)?

    @State private var viewMode: BinaryValueViewMode = .tree
    @State private var document: BinaryValueDocument?
    @State private var hexDump = ""
    @State private var decodedKey: TaskKey?
    @State private var searchText = ""
    @State private var schemaRevision = 0

    init(data: Data, format: BinaryValueFormat, onPopOut: (() -> Void)? = nil) {
        self.data = data
        self.format = format
        self.onPopOut = onPopOut
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: TaskKey(data: data, format: format, schemaRevision: schemaRevision)) {
            await decode()
        }
        .onReceive(NotificationCenter.default.publisher(for: AvroSchemaStore.didAddSchema)) { _ in
            if case .missingSchema? = document { schemaRevision += 1 }
        }
    }

    private struct TaskKey: Equatable {
        let data: Data
        let format: BinaryValueFormat
        let schemaRevision: Int
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            if isDecoded {
                Picker("View Mode", selection: $viewMode) {
                    Text(String(localized: "Tree")).tag(BinaryValueViewMode.tree)
                    Text(String(localized: "Text")).tag(BinaryValueViewMode.text)
                    Text(String(localized: "Hex")).tag(BinaryValueViewMode.hex)
                }
                .viewSwitcherStyle()
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("binary-viewer-mode-picker")
            } else {
                Text(format.displayName)
                    .font(.headline)
            }
            Spacer()
            if let onPopOut {
                Button { onPopOut() } label: {
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

    private var isDecoded: Bool {
        if case .decoded? = document { return true }
        return false
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch document {
        case nil:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .valueStandInBackground()
        case .failed(let error)?:
            VStack(spacing: 0) {
                failureBanner(error)
                Divider()
                hexBody
            }
        case .missingSchema?:
            VStack(spacing: 0) {
                banner(
                    String(localized: "This Mac no longer has the schema chosen for this column, so the stored bytes show. Choose it again with Display As > Avro Schema…"),
                    systemImage: "questionmark.folder"
                )
                Divider()
                hexBody
            }
        case .decoded(let tree, let text, let note)?:
            VStack(spacing: 0) {
                if let note {
                    noteBanner(note)
                    Divider()
                }
                switch viewMode {
                case .tree:
                    treeBody(tree)
                case .text:
                    textBody(text)
                case .hex:
                    hexBody
                }
            }
        }
    }

    @ViewBuilder
    private func treeBody(_ tree: BinaryValueTree) -> some View {
        switch tree {
        case .json(let root):
            JSONTreeView(rootNode: root, searchText: $searchText)
        case .protobuf(let root):
            FilterableTreeView(
                rootNode: root,
                searchText: $searchText,
                fullValueModeName: String(localized: "Text")
            )
        case .php(let root):
            FilterableTreeView(
                rootNode: root,
                searchText: $searchText,
                fullValueModeName: String(localized: "Text")
            )
        }
    }

    private func textBody(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(themeEngine.valueFontSwiftUI)
                .themeForeground(.editorText, native: .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .themeBackground(.editorBackground, native: Color.clear)
    }

    // The dump alone: HexEditorBody brings a Close button the popover, window and inspector each own.
    private var hexBody: some View {
        HexDumpDisplayView(text: hexDump, font: themeEngine.valueFont)
    }

    private func failureBanner(_ error: BinaryValueDecodeError) -> some View {
        banner(
            String(format: String(localized: "Not valid %@. %@ Showing the stored bytes."), format.displayName, error.reason),
            systemImage: "exclamationmark.triangle"
        )
    }

    private func noteBanner(_ note: String) -> some View {
        banner(note, systemImage: "info.circle")
    }

    private func banner(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    // MARK: - Decode

    // A pane added back restarts the task with the same key.
    private func decode() async {
        let key = TaskKey(data: data, format: format, schemaRevision: schemaRevision)
        guard decodedKey != key else { return }
        let data = data
        let format = format
        let (decoded, dump) = await Task.detached(priority: .userInitiated) {
            (
                BinaryValueDecoding.document(data, format: format),
                String(data: data, encoding: .isoLatin1)?.formattedAsHexDump() ?? ""
            )
        }.value
        guard !Task.isCancelled else { return }
        document = decoded
        hexDump = dump
        decodedKey = key
    }
}

//
//  PhpViewerView.swift
//  TablePro
//

import SwiftUI

internal enum PhpViewMode: String, CaseIterable {
    case tree
    case raw
}

internal enum PhpParseResult: Equatable {
    case idle
    case parsing
    case parsed(PhpTreeNode)
    case tooLarge
    case failed

    static func == (lhs: PhpParseResult, rhs: PhpParseResult) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.parsing, .parsing), (.tooLarge, .tooLarge), (.failed, .failed):
            return true
        case (.parsed(let a), .parsed(let b)):
            return a.id == b.id
        default:
            return false
        }
    }
}

@MainActor
internal struct PhpViewerView: View {
    let rawValue: String
    var onDismiss: (() -> Void)?
    var onPopOut: ((String) -> Void)?

    @State private var viewMode: PhpViewMode = .tree
    @State private var parseResult: PhpParseResult = .idle
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            viewerToolbar
            Divider()
            viewerContent
        }
        .task(id: rawValue) {
            await loadParse()
        }
    }

    // MARK: - Toolbar

    private var viewerToolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $viewMode) {
                Text(String(localized: "Tree")).tag(PhpViewMode.tree)
                Text(String(localized: "Raw")).tag(PhpViewMode.raw)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            if let onPopOut {
                Button { onPopOut(rawValue) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Open in Window"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var viewerContent: some View {
        switch viewMode {
        case .tree:
            treeBody
        case .raw:
            rawBody
        }
    }

    @ViewBuilder
    private var treeBody: some View {
        switch parseResult {
        case .idle, .parsing:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .parsed(let node):
            PhpTreeView(rootNode: node, searchText: $searchText)
        case .tooLarge:
            errorPlaceholder(
                title: String(localized: "Value Too Large"),
                detail: String(localized: "This value is too large to parse. Use raw mode to inspect it as text."),
                systemImage: "doc.text"
            )
        case .failed:
            errorPlaceholder(
                title: String(localized: "Invalid PHP Serialized Value"),
                detail: String(localized: "The value could not be parsed. Use raw mode to inspect it as text."),
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private var rawBody: some View {
        ScrollView {
            Text(rawValue)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }

    private func errorPlaceholder(title: String, detail: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        }
    }

    // MARK: - Parse

    private func loadParse() async {
        parseResult = .parsing
        let raw = rawValue
        let parsed = await Task.detached(priority: .userInitiated) { () -> PhpParseResult in
            if (raw as NSString).length > PhpSerializeParser.sizeCapBytes {
                return .tooLarge
            }
            guard let value = PhpSerializeParser.parse(raw) else { return .failed }
            let tree = PhpTreeBuilder.build(from: value)
            return .parsed(tree)
        }.value
        parseResult = parsed
    }
}

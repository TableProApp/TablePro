import SwiftUI
import TableProModels

struct SavedQueryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let query: SavedQuery
    let isRenaming: Bool
    let onOpen: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draftName = ""
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        if isRenaming {
            content
        } else {
            Button(action: onOpen) {
                content
                    .contentShape(Rectangle())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(for: query))
            .accessibilityHint(Text("Replaces the editor's text with this query."))
        }
    }

    static func accessibilityLabel(for query: SavedQuery) -> String {
        var parts = [query.name]
        if query.connectionId == nil {
            parts.append(String(localized: "global"))
        }
        if let keyword = query.keyword, !keyword.isEmpty {
            parts.append(String(format: String(localized: "keyword: %@"), keyword))
        }
        return parts.joined(separator: ", ")
    }

    private var lineLimit: Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : 1
    }

    private var content: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                title
                if let preview = SavedQueryPreview.firstLine(of: query.query) {
                    Text(verbatim: preview)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if query.connectionId == nil {
                Image(systemName: "globe")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            if let keyword = query.keyword, !keyword.isEmpty {
                Text(verbatim: keyword)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var title: some View {
        if isRenaming {
            TextField("Name", text: $draftName)
                .font(.body)
                .focused($isNameFieldFocused)
                .submitLabel(.done)
                .onSubmit { onCommitRename(draftName) }
                .onKeyPress(.escape) {
                    onCancelRename()
                    return .handled
                }
                .onAppear {
                    draftName = query.name
                    isNameFieldFocused = true
                }
                .onChange(of: isNameFieldFocused) { _, focused in
                    guard !focused else { return }
                    onCommitRename(draftName)
                }
        } else {
            Text(verbatim: query.name)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
        }
    }
}

struct SavedQueryFolderLabel: View {
    let folder: SavedQueryFolder

    private var isGlobal: Bool {
        folder.connectionId == nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: folder.name)
                .lineLimit(1)
            Spacer()
            if isGlobal {
                Image(systemName: "globe")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isGlobal ? folder.name + ", " + String(localized: "global") : folder.name)
    }
}

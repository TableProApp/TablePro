//
//  EnumLabelListView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The labels of one enum type in server order, with the two edits PostgreSQL allows: add a
/// label, at the end or beside an existing one, and rename one. A label cannot be removed or
/// moved once it exists, so neither is offered.
///
/// Each edit is one statement that runs when the field commits, because `ALTER TYPE … ADD VALUE`
/// cannot be batched into a transaction on every server that supports it.
struct EnumLabelListView: View {
    let labels: [String]
    let canEdit: Bool
    let canRename: Bool
    let onAdd: (String, EnumLabelPlacement?) async throws -> Void
    let onRename: (String, String) async throws -> Void

    private enum Draft: Equatable {
        case adding(placement: EnumLabelPlacement?)
        case renaming(String)
    }

    private struct Row: Identifiable {
        enum Content: Equatable {
            case label(String)
            case draft
        }

        let id: String
        let content: Content
    }

    @State private var draft: Draft?
    @State private var draftText = ""
    @State private var isApplying = false
    @State private var errorMessage: String?
    @State private var selection: String?
    @FocusState private var isDraftFocused: Bool

    private static let rowHeight: CGFloat = 24
    private static let maxListHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            List(selection: $selection) {
                ForEach(rows) { row in
                    rowView(row)
                        .tag(row.id)
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .frame(height: listHeight)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            if canEdit {
                Divider()
                editBar
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var titleRow: some View {
        HStack {
            Text("Labels")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(labels.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var editBar: some View {
        HStack(spacing: 4) {
            Button(String(localized: "Add Label"), systemImage: "plus") {
                beginAdding(placement: nil)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(draft != nil || isApplying)
            .help(String(localized: "Add a label at the end"))
            if isApplying {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var rows: [Row] {
        var rows = labels.map { Row(id: "label:\($0)", content: .label($0)) }
        switch draft {
        case .adding(let placement):
            let draftRow = Row(id: "draft", content: .draft)
            guard let placement, let anchor = rows.firstIndex(where: { $0.content == .label(placement.anchor) })
            else {
                rows.append(draftRow)
                return rows
            }
            rows.insert(draftRow, at: placement.placesBefore ? anchor : anchor + 1)
        case .renaming(let label):
            guard let index = rows.firstIndex(where: { $0.content == .label(label) }) else { return rows }
            rows[index] = Row(id: "draft", content: .draft)
        case nil:
            break
        }
        return rows
    }

    private var listHeight: CGFloat {
        min(CGFloat(rows.count) * Self.rowHeight + 8, Self.maxListHeight)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row.content {
        case .draft:
            TextField(String(localized: "Label"), text: $draftText)
                .textFieldStyle(.roundedBorder)
                .font(ThemeEngine.shared.valueFontSwiftUI)
                .focused($isDraftFocused)
                .disabled(isApplying)
                .onSubmit { commitDraft() }
                .onExitCommand { cancelDraft() }
                .onAppear { isDraftFocused = true }
        case .label(let label):
            Text(label)
                .font(ThemeEngine.shared.valueFontSwiftUI)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard NSApp.currentEvent?.clickCount == 2 else { return }
                    beginRenaming(label)
                }
                .contextMenu { labelMenu(label) }
        }
    }

    @ViewBuilder
    private func labelMenu(_ label: String) -> some View {
        Button(String(localized: "Copy Label")) {
            ClipboardService.shared.writeText(label)
        }
        if canEdit {
            Divider()
            Button(String(localized: "Add Label Before…")) {
                beginAdding(placement: EnumLabelPlacement(anchor: label, placesBefore: true))
            }
            Button(String(localized: "Add Label After…")) {
                beginAdding(placement: EnumLabelPlacement(anchor: label, placesBefore: false))
            }
            if canRename {
                Button(String(localized: "Rename…")) {
                    beginRenaming(label)
                }
            }
        }
    }

    private func beginAdding(placement: EnumLabelPlacement?) {
        guard canEdit, !isApplying else { return }
        errorMessage = nil
        draftText = ""
        draft = .adding(placement: placement)
    }

    private func beginRenaming(_ label: String) {
        guard canEdit, canRename, !isApplying else { return }
        errorMessage = nil
        draftText = label
        draft = .renaming(label)
    }

    private func cancelDraft() {
        draft = nil
        draftText = ""
    }

    private func commitDraft() {
        guard let draft else { return }
        let text = draftText
        guard !text.isEmpty else {
            cancelDraft()
            return
        }
        if case .renaming(let original) = draft, original == text {
            cancelDraft()
            return
        }
        isApplying = true
        errorMessage = nil
        Task {
            defer { isApplying = false }
            do {
                switch draft {
                case .adding(let placement):
                    try await onAdd(text, placement)
                case .renaming(let original):
                    try await onRename(original, text)
                }
                cancelDraft()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

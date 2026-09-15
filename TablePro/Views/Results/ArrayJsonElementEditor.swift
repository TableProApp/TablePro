//
//  ArrayJsonElementEditor.swift
//  TablePro
//
//  Element list and JSON document pane for an array whose elements are JSON.
//

import SwiftUI
import TableProPluginKit

/// The editor a `jsonb[]` or `json[]` cell opens on.
///
/// The elements are listed above and the selected one opens in the same `JSONViewerView` a scalar
/// JSON cell gets, so an element has the Text and Tree modes, the tree search and the invalid-JSON
/// reporting the rest of the app already has. The array stays a list of documents rather than
/// collapsing into one: `to_jsonb()` writes a SQL NULL element and a JSON null element both as
/// `null`, and that distinction is the point of editing the column in place.
internal struct ArrayJsonElementEditor: View {
    @Binding internal var rows: [ArrayEditorRow]
    @Binding internal var selection: UUID?
    internal let isReadOnly: Bool

    private static let listHeight: CGFloat = 132

    var body: some View {
        VStack(spacing: 0) {
            elementList
            Divider()
            detail
        }
        .onAppear(perform: selectFirstIfNeeded)
        .onChange(of: rows.map(\.id), selectFirstIfNeeded)
    }

    private var elementList: some View {
        List(selection: $selection) {
            /// `ForEach(rows.enumerated(), id:)` is the modern form and does not compile here:
            /// `EnumeratedSequence`'s `RandomAccessCollection` conformance is macOS 26, and the
            /// deployment target is 14. The copy is a constant factor on the identity walk `ForEach`
            /// already does over every row.
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                elementRow(row, index: index)
            }
        }
        .listStyle(.plain)
        .frame(height: Self.listHeight)
        .overlay {
            if rows.isEmpty {
                Text("Empty array")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func elementRow(_ row: ArrayEditorRow, index: Int) -> some View {
        let display = ArrayValueEditorModel.jsonDisplay(of: row.element)
        return HStack(spacing: 6) {
            Text(verbatim: "\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            if let summary = display.summary {
                Text(summary)
                    .font(ThemeEngine.shared.valueFontSwiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("NULL")
                    .italic()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !display.isValid {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Not valid JSON"))
                    .help(Text("This element is not valid JSON"))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let row = selectedRow {
            VStack(spacing: 0) {
                detailHeader(for: row)
                Divider()
                if row.element == .null {
                    nullPlaceholder
                } else {
                    JSONViewerView(text: selectedJsonText, isEditable: !isReadOnly)
                        .id(row.id)
                }
            }
        } else {
            ContentUnavailableView {
                Label(String(localized: "No Element Selected"), systemImage: "list.bullet.rectangle")
            } description: {
                Text("Select an element to read or edit its JSON.")
            }
        }
    }

    private func detailHeader(for row: ArrayEditorRow) -> some View {
        HStack(spacing: 8) {
            Text(elementLabel(for: row))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("NULL", isOn: nullBinding)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(isReadOnly)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var nullPlaceholder: some View {
        Text("NULL")
            .italic()
            .font(ThemeEngine.shared.valueFontSwiftUI)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func elementLabel(for row: ArrayEditorRow) -> String {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return "" }
        return String(format: String(localized: "Element %d"), index + 1)
    }

    private var selectedRow: ArrayEditorRow? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
    }

    /// A NULL element keeps no text of its own, so turning NULL off starts from an empty JSON
    /// object rather than from an empty string, which is not a JSON document.
    private var nullBinding: Binding<Bool> {
        Binding(
            get: { selectedRow?.element == .null },
            set: { isNull in
                mutateSelected { $0.element = isNull ? .null : .value("{}") }
            }
        )
    }

    private var selectedJsonText: Binding<String> {
        Binding(
            get: {
                guard let row = selectedRow, case .value(let value) = row.element else { return "" }
                return value
            },
            set: { newValue in
                mutateSelected { $0.element = .value(newValue) }
            }
        )
    }

    private func mutateSelected(_ transform: (inout ArrayEditorRow) -> Void) {
        guard let selection, let index = rows.firstIndex(where: { $0.id == selection }) else { return }
        transform(&rows[index])
    }

    private func selectFirstIfNeeded() {
        if let selection, rows.contains(where: { $0.id == selection }) { return }
        selection = rows.first?.id
    }
}

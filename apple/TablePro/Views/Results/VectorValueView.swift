//
//  VectorValueView.swift
//  TablePro
//

import SwiftUI

internal struct VectorValueView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    let expectedDimensions: Int?
    let isEditable: Bool
    let onCommit: (String) -> Void
    let onDismiss: () -> Void

    private let original: String
    @State private var text: String
    @State private var isEditingText: Bool
    @State private var shown: VectorLiteral?
    @State private var selection = Set<Int>()

    // A value the list cannot read opens on its own text rather than an empty list.
    init(
        literal: String,
        expectedDimensions: Int?,
        isEditable: Bool,
        onCommit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.expectedDimensions = expectedDimensions
        self.isEditable = isEditable
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self.original = literal
        let parsed = VectorLiteral.parse(literal)
        _text = State(initialValue: literal)
        _shown = State(initialValue: parsed)
        _isEditingText = State(initialValue: parsed == nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isEditingText {
                textEditor
            } else {
                elementTable
            }
            Divider()
            footer
        }
        .frame(width: 360, height: Self.height(for: shown?.elements.count ?? 0))
        .onExitCommand(perform: onDismiss)
    }

    private static func height(for rowCount: Int) -> CGFloat {
        min(460, max(260, CGFloat(rowCount) * 24 + 140))
    }

    private var header: some View {
        HStack(spacing: 8) {
            dimensionsText
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(toggleTitle, action: toggleTextEditing)
                .buttonStyle(.link)
                .font(.caption)
                .disabled(isEditingText && VectorLiteral.parse(text) == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var dimensionsText: some View {
        if let vector = isEditingText ? VectorLiteral.parse(text) : shown {
            if vector.isSparse {
                Text("^[\(vector.dimensions) dimension](inflect: true), \(vector.elements.count) nonzero")
            } else {
                Text("^[\(vector.dimensions) dimension](inflect: true)")
            }
        } else {
            Text("Not a vector")
        }
    }

    private var toggleTitle: LocalizedStringKey {
        if isEditingText { return "View Elements" }
        return isEditable ? "Edit as Text" : "View as Text"
    }

    private var elementTable: some View {
        Table(shown?.elements ?? [], selection: $selection) {
            TableColumn("Index") { element in
                Text(element.index, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 48, ideal: 64, max: 96)
            TableColumn("Value") { element in
                Text(element.text)
                    .font(themeEngine.valueFontSwiftUI)
            }
        }
        .onCopyCommand {
            let values = (shown?.elements ?? []).filter { selection.contains($0.id) }.map(\.text)
            guard !values.isEmpty else { return [] }
            return [NSItemProvider(object: values.joined(separator: "\n") as NSString)]
        }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextValueEditor(
                text: $text,
                isEditable: isEditable,
                font: themeEngine.valueFont,
                textContainerInset: .zero,
                style: .code
            )
            .frame(minHeight: 90)
            if let problem = textProblem {
                Label {
                    problem
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var textProblem: Text? {
        guard isEditable else { return nil }
        guard let vector = VectorLiteral.parse(text) else {
            return Text("This is not a vector value. Write it as [1,2,3].")
        }
        guard let expected = wrongLength(of: vector) else { return nil }
        return Text("This column takes ^[\(expected) dimension](inflect: true). The value has \(vector.dimensions).")
    }

    private func wrongLength(of vector: VectorLiteral) -> Int? {
        guard let expectedDimensions, vector.dimensions != expectedDimensions else { return nil }
        return expectedDimensions
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Copy as JSON", action: copyJSON)
                .disabled(currentVector == nil)
            Spacer()
            if isEditable {
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("OK", action: commitAndDismiss)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            } else {
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var currentVector: VectorLiteral? {
        isEditingText ? VectorLiteral.parse(text) : shown
    }

    // Text the parser cannot read still goes to the server, which owns the grammar; a length the column
    // refuses does not.
    private var canCommit: Bool {
        guard let vector = VectorLiteral.parse(text) else { return true }
        return wrongLength(of: vector) == nil
    }

    private func toggleTextEditing() {
        if isEditingText {
            guard let parsed = VectorLiteral.parse(text) else { return }
            shown = parsed
            selection = []
            isEditingText = false
        } else {
            isEditingText = true
        }
    }

    private func copyJSON() {
        guard let vector = currentVector else { return }
        ClipboardService.shared.writeText(vector.jsonText)
    }

    private func commitAndDismiss() {
        if text != original {
            onCommit(text)
        }
        onDismiss()
    }
}

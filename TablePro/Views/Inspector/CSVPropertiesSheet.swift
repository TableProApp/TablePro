//
//  CSVPropertiesSheet.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct CSVPropertiesSheet: View {
    private let baseDialect: CSVDialect
    private let onReload: (CSVDialect) -> Void
    private let onCancel: () -> Void

    @State private var delimiterIndex: Int
    @State private var quoteIndex: Int
    @State private var escapeIndex: Int
    @State private var encodingIndex: Int
    @State private var lineEndingIndex: Int

    init(
        dialect: CSVDialect,
        onReload: @escaping (CSVDialect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.baseDialect = dialect
        self.onReload = onReload
        self.onCancel = onCancel
        _delimiterIndex = State(initialValue: CSVPropertyOptions.delimiterIndex(for: dialect.delimiter))
        _quoteIndex = State(initialValue: CSVPropertyOptions.quoteIndex(for: dialect.quoteChar))
        _escapeIndex = State(initialValue: CSVPropertyOptions.escapeIndex(for: dialect.escapeChar))
        _encodingIndex = State(initialValue: CSVPropertyOptions.encodingIndex(for: dialect.encoding))
        _lineEndingIndex = State(initialValue: CSVPropertyOptions.lineEndingIndex(for: dialect.lineEnding))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CSV Properties").font(.headline)
            Text("Re-read the file with these settings. This discards unsaved changes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Form {
                Picker("Delimiter", selection: $delimiterIndex) {
                    ForEach(CSVPropertyOptions.delimiters.indices, id: \.self) { index in
                        Text(CSVPropertyOptions.delimiters[index].label).tag(index)
                    }
                }
                Picker("Quote character", selection: $quoteIndex) {
                    ForEach(CSVPropertyOptions.quotes.indices, id: \.self) { index in
                        Text(CSVPropertyOptions.quotes[index].label).tag(index)
                    }
                }
                Picker("Escape character", selection: $escapeIndex) {
                    ForEach(CSVPropertyOptions.escapes.indices, id: \.self) { index in
                        Text(CSVPropertyOptions.escapes[index].label).tag(index)
                    }
                }
                Picker("Encoding", selection: $encodingIndex) {
                    ForEach(CSVPropertyOptions.encodings.indices, id: \.self) { index in
                        Text(CSVPropertyOptions.encodings[index].label).tag(index)
                    }
                }
                Picker("Line ending", selection: $lineEndingIndex) {
                    ForEach(CSVPropertyOptions.lineEndings.indices, id: \.self) { index in
                        Text(CSVPropertyOptions.lineEndings[index].label).tag(index)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Reload") { onReload(selectedDialect) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var selectedDialect: CSVDialect {
        CSVPropertyOptions.dialect(
            base: baseDialect,
            delimiterIndex: delimiterIndex,
            quoteIndex: quoteIndex,
            escapeIndex: escapeIndex,
            encodingIndex: encodingIndex,
            lineEndingIndex: lineEndingIndex
        )
    }
}

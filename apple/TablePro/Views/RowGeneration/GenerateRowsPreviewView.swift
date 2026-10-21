//
//  GenerateRowsPreviewView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

internal struct GenerateRowsPreviewView: View {
    @ObservedObject internal var session: RowGenerationSession

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Preview"))
                .font(.subheadline.weight(.medium))
            switch session.preview {
            case .success(let preview):
                table(preview)
            case .failure(let error):
                message(error.localizedDescription)
            case nil:
                message(String(localized: "Fix the settings above to see the first rows."))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func table(_ preview: RowGenerationPreview) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    ForEach(preview.columns.indices, id: \.self) { index in
                        Text(preview.columns[index])
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                Divider()
                ForEach(preview.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(preview.rows[row].indices, id: \.self) { column in
                            cell(preview.rows[row][column])
                        }
                    }
                }
            }
            .padding(.bottom, 4)
        }
        .accessibilityIdentifier("generate-rows-preview")
    }

    @ViewBuilder
    private func cell(_ value: PluginCellValue) -> some View {
        switch value {
        case .null:
            Text(verbatim: "NULL")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        case .text(let text):
            Text(verbatim: text)
                .font(.caption.monospaced())
                .lineLimit(1)
                .frame(maxWidth: 240, alignment: .leading)
        case .bytes(let data):
            Text(verbatim: "0x" + data.prefix(8).map { String(format: "%02X", $0) }.joined())
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

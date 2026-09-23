//
//  FileConflictDiffSheet.swift
//  TablePro
//

import SwiftUI

internal struct FileConflictDiffSheet: View {
    let fileName: String
    let mineContent: String
    let diskContent: String
    let onKeepMine: () -> Void
    let onReload: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var presentation: FileConflictPresentation?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            diffBody
            Divider()
            footer
        }
        .frame(minWidth: 600, idealWidth: 760, maxWidth: .infinity,
               minHeight: 400, idealHeight: 540, maxHeight: .infinity)
        .task {
            presentation = await FileConflictPresentation.load(mine: mineContent, disk: diskContent)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "File Modified Externally"))
                .font(.headline)
            Text(String(format: String(localized: "\"%@\" was changed since you opened it. Review the diff and choose how to resolve."), fileName))
                .font(.caption)
                .foregroundStyle(.secondary)
            if presentation?.showsLineDiff == false {
                Text(String(localized: "Too many lines differ to compare line by line."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    @ViewBuilder
    private var diffBody: some View {
        if let presentation {
            HSplitView {
                DiffColumnView(title: String(localized: "Your Changes"), rows: presentation.mineRows)
                    .frame(minWidth: 200)

                DiffColumnView(title: String(localized: "On Disk"), rows: presentation.diskRows)
                    .frame(minWidth: 200)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()

            Button(String(localized: "Cancel")) {
                onCancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(String(localized: "Reload from Disk")) {
                onReload()
                dismiss()
            }

            Button(String(localized: "Keep My Changes")) {
                onKeepMine()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }
}

private struct DiffColumnView: View {
    let title: String
    let rows: [FileConflictRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: "\(row.id + 1)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 32, alignment: .trailing)

                            Text(row.text ?? " ")
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(row.highlight.tint)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private extension FileConflictRowHighlight {
    var tint: Color {
        switch self {
        case .plain: return .clear
        case .removed: return .red.opacity(0.18)
        case .added: return .green.opacity(0.18)
        case .filler: return .gray.opacity(0.06)
        }
    }
}

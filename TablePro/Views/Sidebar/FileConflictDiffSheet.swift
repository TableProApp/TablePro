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

    private var diffLines: [DiffPair] {
        FileConflictDiff.pairs(mine: mineContent, disk: diskContent)
    }

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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "File Modified Externally"))
                .font(.headline)
            Text(String(format: String(localized: "\"%@\" was changed since you opened it. Review the diff and choose how to resolve."), fileName))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var diffBody: some View {
        HSplitView {
            DiffColumnView(
                title: String(localized: "Your Changes"),
                lines: diffLines.map {
                    DiffColumnLine(
                        text: $0.before,
                        tint: tint(for: $0.kind, side: .mine)
                    )
                }
            )
            .frame(minWidth: 200)

            DiffColumnView(
                title: String(localized: "On Disk"),
                lines: diffLines.map {
                    DiffColumnLine(
                        text: $0.after,
                        tint: tint(for: $0.kind, side: .disk)
                    )
                }
            )
            .frame(minWidth: 200)
        }
    }

    private enum Side { case mine, disk }

    private func tint(for kind: DiffPair.Kind, side: Side) -> Color? {
        switch (kind, side) {
        case (.unchanged, _): return nil
        case (.removed, .mine): return .red.opacity(0.18)
        case (.removed, .disk): return Color.gray.opacity(0.06)
        case (.added, .mine): return Color.gray.opacity(0.06)
        case (.added, .disk): return .green.opacity(0.18)
        case (.changed, .mine): return .red.opacity(0.18)
        case (.changed, .disk): return .green.opacity(0.18)
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

internal struct DiffColumnLine {
    let text: String?
    let tint: Color?
}

private struct DiffColumnView: View {
    let title: String
    let lines: [DiffColumnLine]

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
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: "\(index + 1)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 32, alignment: .trailing)

                            Text(line.text ?? " ")
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(line.tint ?? Color.clear)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

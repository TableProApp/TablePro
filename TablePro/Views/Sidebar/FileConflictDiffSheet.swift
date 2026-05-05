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
        let mineLines = mineContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let diskLines = diskContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return DiffComputer.compute(mine: mineLines, disk: diskLines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            diffBody
            Divider()
            footer
        }
        .frame(width: 760, height: 540)
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
                lines: diffLines.map { ($0.mine, $0.kind == .removed || $0.kind == .changed) }
            )
            .frame(minWidth: 200)

            DiffColumnView(
                title: String(localized: "On Disk"),
                lines: diffLines.map { ($0.disk, $0.kind == .added || $0.kind == .changed) }
            )
            .frame(minWidth: 200)
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
    let lines: [(text: String?, highlight: Bool)]

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
                            Text("\(index + 1)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 32, alignment: .trailing)

                            Text(line.text ?? "")
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(line.highlight
                                    ? Color(nsColor: .systemYellow).opacity(0.15)
                                    : Color.clear)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

internal struct DiffPair {
    enum Kind { case unchanged, added, removed, changed }
    let mine: String?
    let disk: String?
    let kind: Kind
}

internal enum DiffComputer {
    static func compute(mine: [String], disk: [String]) -> [DiffPair] {
        let difference = disk.difference(from: mine)
        var pairs: [DiffPair] = []
        var mineIndex = 0
        var diskIndex = 0

        var insertions: [Int: String] = [:]
        var removals: [Int: String] = [:]
        for change in difference {
            switch change {
            case .insert(let offset, let element, _):
                insertions[offset] = element
            case .remove(let offset, let element, _):
                removals[offset] = element
            }
        }

        while mineIndex < mine.count || diskIndex < disk.count {
            if let removed = removals[mineIndex] {
                pairs.append(DiffPair(mine: removed, disk: nil, kind: .removed))
                mineIndex += 1
                continue
            }
            if let added = insertions[diskIndex] {
                pairs.append(DiffPair(mine: nil, disk: added, kind: .added))
                diskIndex += 1
                continue
            }
            if mineIndex < mine.count, diskIndex < disk.count {
                pairs.append(DiffPair(mine: mine[mineIndex], disk: disk[diskIndex], kind: .unchanged))
                mineIndex += 1
                diskIndex += 1
            } else {
                break
            }
        }

        return pairs
    }
}

//
//  StructureDefinitionDiffView.swift
//  TablePro
//
//  Source and target definitions side by side. Both sides are rendered from
//  parsed metadata through the same function, so only real differences show.
//  Difference type carries a glyph as well as a colour.
//

import SwiftUI

internal struct StructureDefinitionDiffView: View {
    internal let sourceLines: [String]
    internal let targetLines: [String]

    @State private var isUnified = false

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var pairs: [DiffPair] {
        DiffComputer.computeSplit(before: targetLines, after: sourceLines)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Definition")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("", selection: $isUnified) {
                    Text("Split").tag(false)
                    Text("Unified").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.bottom, 6)

            if isUnified {
                unifiedBody
            } else {
                splitBody
            }
        }
    }

    private var splitBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                columnHeader(String(localized: "Target"))
                columnHeader(String(localized: "Source"))
            }
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 0) {
                    diffCell(pair.before, kind: pair.kind, isBefore: true)
                    diffCell(pair.after, kind: pair.kind, isBefore: false)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
    }

    private var unifiedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(DiffComputer.computeUnified(from: pairs)) { line in
                HStack(spacing: 6) {
                    Text(marker(for: line.kind))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(width: 12)
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(background(for: line.kind))
            }
        }
        .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
    }

    private func diffCell(_ text: String?, kind: DiffPair.Kind, isBefore: Bool) -> some View {
        HStack(spacing: 4) {
            Text(glyph(for: kind, isBefore: isBefore))
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 10)
            Text(text ?? "")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(splitBackground(kind: kind, isBefore: isBefore, isEmpty: text == nil))
    }

    private func glyph(for kind: DiffPair.Kind, isBefore: Bool) -> String {
        switch kind {
        case .unchanged: return " "
        case .changed: return "~"
        case .added: return isBefore ? " " : "+"
        case .removed: return isBefore ? "-" : " "
        }
    }

    private func marker(for kind: DiffUnifiedLine.Kind) -> String {
        switch kind {
        case .context: return " "
        case .added: return "+"
        case .removed: return "-"
        }
    }

    private func splitBackground(kind: DiffPair.Kind, isBefore: Bool, isEmpty: Bool) -> Color {
        guard !differentiateWithoutColor else { return .clear }
        guard !isEmpty else { return Color.secondary.opacity(0.05) }
        switch kind {
        case .unchanged: return .clear
        case .changed: return CompareStatusStyle.rowTint(for: .update)
        case .added: return isBefore ? .clear : CompareStatusStyle.rowTint(for: .insert)
        case .removed: return isBefore ? CompareStatusStyle.rowTint(for: .delete) : .clear
        }
    }

    private func background(for kind: DiffUnifiedLine.Kind) -> Color {
        guard !differentiateWithoutColor else { return .clear }
        switch kind {
        case .context: return .clear
        case .added: return CompareStatusStyle.rowTint(for: .insert)
        case .removed: return CompareStatusStyle.rowTint(for: .delete)
        }
    }
}

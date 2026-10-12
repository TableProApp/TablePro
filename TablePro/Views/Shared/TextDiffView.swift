//
//  TextDiffView.swift
//  TablePro
//

import SwiftUI

internal enum TextDiffLayout: Hashable {
    case split
    case unified
}

internal struct TextDiffView: View {
    internal let pairs: [DiffPair]
    internal let beforeLabel: String
    internal let afterLabel: String
    internal let layout: TextDiffLayout
    internal var textFont: Font = .system(.caption, design: .monospaced)

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    internal var body: some View {
        switch layout {
        case .split:
            splitBody
        case .unified:
            unifiedBody
        }
    }

    private var splitBody: some View {
        LazyVStack(spacing: 0) {
            HStack(spacing: 0) {
                columnHeader(beforeLabel)
                columnHeader(afterLabel)
            }
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 0) {
                    diffCell(pair.before, kind: pair.kind, side: .before)
                    diffCell(pair.after, kind: pair.kind, side: .after)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
    }

    private var unifiedBody: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(DiffComputer.computeUnified(from: pairs)) { line in
                HStack(spacing: 6) {
                    Text(verbatim: marker(for: line.kind))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(verbatim: line.text)
                        .font(textFont)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(background(for: line.kind))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: line))
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

    private func diffCell(_ text: String?, kind: DiffPair.Kind, side: SqlWalkthroughAnchor.Side) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: SplitDiffMarker.resolve(kind: kind, side: side)?.glyph ?? " ")
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 10)
                .accessibilityHidden(true)
            Text(verbatim: text ?? "")
                .font(textFont)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(splitBackground(kind: kind, side: side, isEmpty: text == nil))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: text, kind: kind, side: side))
    }

    private func marker(for kind: DiffUnifiedLine.Kind) -> String {
        switch kind {
        case .context: return " "
        case .added: return SplitDiffMarker.added.glyph
        case .removed: return SplitDiffMarker.removed.glyph
        }
    }

    private func accessibilityLabel(for line: DiffUnifiedLine) -> String {
        switch line.kind {
        case .context:
            return line.text
        case .added:
            return String(format: String(localized: "%@: %@"), SplitDiffMarker.added.label, line.text)
        case .removed:
            return String(format: String(localized: "%@: %@"), SplitDiffMarker.removed.label, line.text)
        }
    }

    private func accessibilityLabel(for text: String?, kind: DiffPair.Kind, side: SqlWalkthroughAnchor.Side) -> String {
        guard let text else { return "" }
        guard let marker = SplitDiffMarker.resolve(kind: kind, side: side) else { return text }
        return String(format: String(localized: "%@: %@"), marker.label, text)
    }

    private func splitBackground(kind: DiffPair.Kind, side: SqlWalkthroughAnchor.Side, isEmpty: Bool) -> Color {
        guard !differentiateWithoutColor else { return .clear }
        guard !isEmpty else { return Color.secondary.opacity(0.05) }
        switch (kind, side) {
        case (.unchanged, _): return .clear
        case (.changed, _): return CompareStatusStyle.rowTint(for: .update)
        case (.added, .after): return CompareStatusStyle.rowTint(for: .insert)
        case (.removed, .before): return CompareStatusStyle.rowTint(for: .delete)
        default: return .clear
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

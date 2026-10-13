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
    @ObservedObject private var themeEngine = ThemeEngine.shared

    private static let outline = RoundedRectangle(cornerRadius: 4)

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
        .background(Self.outline.stroke(Color.secondary.opacity(0.2)))
        .themeBackground(.editorBackground, native: Color.clear, in: Self.outline)
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
                .diffLineForeground(Self.lineKind(line.kind))
                .background(background(for: line.kind))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: line))
            }
        }
        .background(Self.outline.stroke(Color.secondary.opacity(0.2)))
        .themeBackground(.editorBackground, native: Color.clear, in: Self.outline)
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
        .diffLineForeground(Self.lineKind(kind, side: side))
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
        guard let lineKind = Self.lineKind(kind, side: side) else { return .clear }
        return CompareStatusStyle.rowTint(for: lineKind, palette: themeEngine.palette)
    }

    private func background(for kind: DiffUnifiedLine.Kind) -> Color {
        guard !differentiateWithoutColor, let lineKind = Self.lineKind(kind) else { return .clear }
        return CompareStatusStyle.rowTint(for: lineKind, palette: themeEngine.palette)
    }

    internal static func lineKind(_ kind: DiffPair.Kind, side: SqlWalkthroughAnchor.Side) -> RowDiffKind? {
        switch (kind, side) {
        case (.changed, _): return .update
        case (.added, .after): return .insert
        case (.removed, .before): return .delete
        default: return nil
        }
    }

    internal static func lineKind(_ kind: DiffUnifiedLine.Kind) -> RowDiffKind? {
        switch kind {
        case .context: return nil
        case .added: return .insert
        case .removed: return .delete
        }
    }
}

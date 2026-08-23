//
//  CompareStatusBar.swift
//  TablePro
//
//  The window's bottom bar: what the comparison found, and how much of it the
//  user has included.
//
//  Counts only, never an action. The HIG asks an app to avoid putting critical
//  information or actions in a bottom bar and to "use it only to display a small
//  amount of information directly related to a window's contents or to a
//  selected item within it", with Finder's item and selection counts as the
//  example. Compare, Generate Script and Apply stay in the toolbar and in the
//  Database > Compare menu, which is also the only place they are reachable when
//  the window's bottom edge is off screen.
//
//  It keeps the same four cells in both modes. Data mode reuses the structure
//  vocabulary because an insert is a row that exists only on the source, so the
//  bar never changes shape when the mode does.
//

import SwiftUI

internal struct CompareStatusBar: View {
    @Bindable internal var session: CompareSyncSession

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    internal var body: some View {
        HStack(spacing: StatusBarChrome.clusterSpacing) {
            content
        }
        .statusBarChrome()
    }

    /// A resting line rather than nothing at all, so the bar does not appear and disappear under the
    /// content and shift everything above it the first time a comparison finishes.
    @ViewBuilder
    private var content: some View {
        let counts = session.statusCounts
        if counts.isEmpty {
            Text("No comparison yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        } else {
            ForEach(counts) { entry in
                statusCount(entry)
            }
            Spacer(minLength: StatusBarChrome.clusterSpacing)
            includedCount
        }
    }

    private func statusCount(_ entry: CompareStatusCount) -> some View {
        let title = CompareStatusStyle.title(for: entry.status)
        return HStack(spacing: 4) {
            Image(systemName: CompareStatusStyle.symbolName(for: entry.status))
                .foregroundStyle(tint(for: entry))
            Text(entry.count, format: .number)
                .monospacedDigit()
                .fontWeight(.semibold)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(Text(entry.count, format: .number))
        .accessibilityIdentifier("compare.status.\(entry.status.rawValue)")
    }

    private var includedCount: some View {
        Text(includedText)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityIdentifier("compare.status.included")
    }

    private var includedText: String {
        String(format: String(localized: "%d included"), session.includedCount)
    }

    /// Colour is never the only carrier: every cell pairs the tint with the status symbol and its
    /// word, and drops the tint when the system asks for shapes instead of colour. A zero reads as a
    /// zero rather than as a green success.
    private func tint(for entry: CompareStatusCount) -> Color {
        let value = entry.count
        guard value > 0 else { return .secondary }
        guard !differentiateWithoutColor else { return .primary }
        return CompareStatusStyle.tint(for: entry.status)
    }
}

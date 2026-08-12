//
//  EditorTabStrip.swift
//  TablePro
//

import SwiftUI

/// The editor tabs for one connection, drawn to match the system tab bar. Native window tabs
/// cannot express this: a window belongs to exactly one tab group and a group's bar shows every
/// window in it, so one window hosting several connections could only ever show all of their
/// tabs interleaved.
///
/// The geometry follows the system bar rather than inventing one: an inset rounded container,
/// tabs of equal width filling it, the selected tab as a raised card, and a separator only
/// between two unselected neighbours.
internal struct EditorTabStrip: View {
    internal let tabManager: QueryTabManager
    internal let onClose: (UUID) -> Void
    internal let onNewTab: () -> Void

    internal var body: some View {
        HStack(spacing: Metrics.barSpacing) {
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                            EditorTabStripItem(
                                tab: tab,
                                isSelected: isSelected(tab),
                                showsLeadingSeparator: showsSeparator(before: index),
                                onSelect: { tabManager.selectedTabId = tab.id },
                                onClose: { onClose(tab.id) }
                            )
                            .frame(width: tabWidth(forTotal: proxy.size.width))
                        }
                    }
                }
                /// The bar has to read as a recess the selected card sits proud of.
                /// `controlColor` renders near white, so the card lost all separation from it.
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                        .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                )
                .clipShape(
                    RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                )
            }
            .frame(height: Metrics.barHeight)

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: Metrics.barHeight, height: Metrics.barHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("New Tab"))
            .accessibilityLabel(Text("New Tab"))
        }
        .padding(.horizontal, Metrics.barInset)
        .padding(.vertical, Metrics.barInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Editor Tabs"))
    }

    private func isSelected(_ tab: QueryTab) -> Bool {
        tabManager.selectedTab?.id == tab.id
    }

    /// The system bar rules a line between two plain tabs only. A separator touching the raised
    /// card reads as a seam in the card, which is the tell that a bar was drawn by hand.
    private func showsSeparator(before index: Int) -> Bool {
        guard index > 0 else { return false }
        let tabs = tabManager.tabs
        guard tabs.indices.contains(index), tabs.indices.contains(index - 1) else { return false }
        return !isSelected(tabs[index]) && !isSelected(tabs[index - 1])
    }

    /// Tabs share the bar equally, the way the system bar lays them out, and stop shrinking at a
    /// width that still fits a name so a long list scrolls instead of collapsing into slivers.
    private func tabWidth(forTotal total: CGFloat) -> CGFloat {
        let count = CGFloat(max(tabManager.tabs.count, 1))
        return max(total / count, Metrics.minimumTabWidth)
    }

    internal enum Metrics {
        internal static let barHeight: CGFloat = 28
        internal static let barInset: CGFloat = 8
        internal static let barSpacing: CGFloat = 4
        internal static let cornerRadius: CGFloat = 9
        internal static let minimumTabWidth: CGFloat = 110
        internal static var totalHeight: CGFloat { barHeight + barInset * 2 }
    }
}

private struct EditorTabStripItem: View {
    let tab: QueryTab
    let isSelected: Bool
    let showsLeadingSeparator: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            if showsLeadingSeparator {
                HStack {
                    Divider().frame(height: Self.separatorHeight)
                    Spacer()
                }
            }

            selectionBackground

            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .italic(tab.isPreview)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                .padding(.horizontal, Self.titleInset)

            /// Leading, like every system tab bar, and overlaid so revealing it on hover never
            /// shifts the title out from under the pointer.
            HStack {
                closeButton
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .help(Text(tab.title))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Close Tab"), onClose)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
                .padding(Self.cardInset)
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if isHovering {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: Self.closeButtonSize, height: Self.closeButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, Self.closeButtonInset)
            .accessibilityLabel(Text("Close Tab"))
        }
    }

    private static let cardCornerRadius: CGFloat = 7
    private static let cardInset: CGFloat = 2
    private static let closeButtonSize: CGFloat = 16
    private static let closeButtonInset: CGFloat = 5
    private static let separatorHeight: CGFloat = 14
    private static let titleInset: CGFloat = 24
}

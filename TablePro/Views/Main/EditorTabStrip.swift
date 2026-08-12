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

    @State private var hoveredTabId: UUID?

    internal var body: some View {
        HStack(spacing: Metrics.barSpacing) {
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                            EditorTabStripItem(
                                tab: tab,
                                isSelected: isSelected(tab),
                                isHovered: hoveredTabId == tab.id,
                                showsLeadingSeparator: showsSeparator(before: index),
                                onHover: { hoveredTabId = $0 ? tab.id : (hoveredTabId == tab.id ? nil : hoveredTabId) },
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

    /// The system rules a line only between two neighbours that are both plain and both
    /// untouched. A separator against the raised card reads as a seam in the card, and one
    /// against a hovered tab fights its fill. Two tabs therefore never show one, because one
    /// of them is always selected.
    private func showsSeparator(before index: Int) -> Bool {
        guard index > 0 else { return false }
        let tabs = tabManager.tabs
        guard tabs.indices.contains(index), tabs.indices.contains(index - 1) else { return false }
        let leading = tabs[index - 1]
        let trailing = tabs[index]
        guard !isSelected(leading), !isSelected(trailing) else { return false }
        return hoveredTabId != leading.id && hoveredTabId != trailing.id
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
        internal static let minimumTabWidth: CGFloat = 120
        internal static var totalHeight: CGFloat { barHeight + barInset * 2 }
    }
}

private struct EditorTabStripItem: View {
    let tab: QueryTab
    let isSelected: Bool
    let isHovered: Bool
    let showsLeadingSeparator: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if showsLeadingSeparator {
                HStack {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1, height: Self.separatorHeight)
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
        .onHover(perform: onHover)
        .onTapGesture(perform: onSelect)
        .help(Text(tab.title))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Close Tab"), onClose)
    }

    /// The tab is a capsule, so its radius follows its own height rather than a fixed number.
    /// An unselected tab is not inert: hovering fills it a shade deeper than the track, which
    /// is what tells the pointer it landed on something.
    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
                .padding(Self.cardInset)
        } else if isHovered {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .separatorColor).opacity(Self.hoverFillOpacity))
                .padding(Self.cardInset)
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if isHovered {
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

    private static let cardInset: CGFloat = 2
    private static let closeButtonSize: CGFloat = 16
    private static let closeButtonInset: CGFloat = 5
    private static let hoverFillOpacity: CGFloat = 0.5
    private static let separatorHeight: CGFloat = 18
    private static let titleInset: CGFloat = 24
}

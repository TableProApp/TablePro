//
//  EditorTabStrip.swift
//  TablePro
//

import SwiftUI

/// The editor tabs for one connection, built to the system tab bar's own geometry. Native window
/// tabs cannot express this: a window belongs to exactly one tab group and a group's bar shows
/// every window in it, so one window hosting several connections could only ever show all of
/// their tabs interleaved.
///
/// Every number here was read off `NSTabBar`'s live view tree rather than guessed. The system
/// nests glass inside glass: a subdued glass track holding a glass capsule per tab. Apple warns
/// against layering glass in general, so the exception is followed only because the control being
/// matched is built that way.
internal struct EditorTabStrip: View {
    internal let tabManager: QueryTabManager
    internal let onClose: (UUID) -> Void
    internal let onNewTab: () -> Void

    @State private var hoveredTabId: UUID?

    internal var body: some View {
        HStack(spacing: Metrics.trackSpacing) {
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                            EditorTabStripItem(
                                tab: tab,
                                isSelected: isSelected(tab),
                                isHovered: hoveredTabId == tab.id,
                                showsLeadingSeparator: showsSeparator(before: index),
                                onHover: { hovering in
                                    if hovering {
                                        hoveredTabId = tab.id
                                    } else if hoveredTabId == tab.id {
                                        hoveredTabId = nil
                                    }
                                },
                                onSelect: { tabManager.selectedTabId = tab.id },
                                onClose: { onClose(tab.id) }
                            )
                            .frame(width: tabWidth(forTrack: proxy.size.width))
                        }
                    }
                }
                .frame(height: Metrics.tabHeight)
                .padding(Metrics.trackPadding)
                .trackGlass()
            }
            .frame(height: Metrics.trackHeight)

            newTabButton
        }
        .padding(.horizontal, Metrics.stripInset)
        .padding(.vertical, Metrics.stripInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Editor Tabs"))
    }

    private var newTabButton: some View {
        Button(action: onNewTab) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: Metrics.trackHeight, height: Metrics.trackHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .trackGlass()
        .help(Text("New Tab"))
        .accessibilityLabel(Text("New Tab"))
    }

    private func isSelected(_ tab: QueryTab) -> Bool {
        tabManager.selectedTab?.id == tab.id
    }

    /// The system rules a line only between two neighbours that are both plain and both
    /// untouched. A separator against the raised capsule reads as a seam in it, and one against
    /// a hovered tab fights that tab's fill. Two tabs therefore never show one, because one of
    /// them is always selected.
    private func showsSeparator(before index: Int) -> Bool {
        guard index > 0 else { return false }
        let tabs = tabManager.tabs
        guard tabs.indices.contains(index), tabs.indices.contains(index - 1) else { return false }
        let leading = tabs[index - 1]
        let trailing = tabs[index]
        guard !isSelected(leading), !isSelected(trailing) else { return false }
        return hoveredTabId != leading.id && hoveredTabId != trailing.id
    }

    /// Tabs share the track equally, the way the system lays them out, and stop shrinking at a
    /// width that still fits a name so a long list scrolls instead of collapsing into slivers.
    private func tabWidth(forTrack width: CGFloat) -> CGFloat {
        let usable = width - Metrics.trackPadding * 2
        let count = CGFloat(max(tabManager.tabs.count, 1))
        return max(usable / count, Metrics.minimumTabWidth)
    }

    internal enum Metrics {
        internal static let trackHeight: CGFloat = 28
        internal static let tabHeight: CGFloat = 24
        internal static let trackPadding: CGFloat = 2
        internal static let stripInset: CGFloat = 8
        internal static let trackSpacing: CGFloat = 4
        internal static let minimumTabWidth: CGFloat = 120
        internal static var totalHeight: CGFloat { trackHeight + stripInset * 2 }
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

            background

            /// The close button occupies the leading end and an equal spacer holds the trailing
            /// end, which is how the system keeps a title optically centred while still giving
            /// the button a real place in the row.
            HStack(spacing: 0) {
                closeButton
                    .frame(width: Self.accessoryWidth)
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .italic(tab.isPreview)
                    .font(.system(size: Self.fontSize))
                    .foregroundStyle(
                        isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor)
                    )
                    .frame(maxWidth: .infinity)
                Color.clear
                    .frame(width: Self.accessoryWidth)
            }
            .padding(.horizontal, Self.accessoryInset)
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

    /// The selected tab is the glass capsule the system raises out of the track. An unselected
    /// one is not inert either: hovering fills it so the pointer has something to land on.
    @ViewBuilder
    private var background: some View {
        if isSelected {
            Color.clear.tabGlass()
        } else if isHovered {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .separatorColor).opacity(Self.hoverFillOpacity))
        }
    }

    /// Shown for the tab in front at all times, and for any tab the pointer is over, so closing
    /// the visible tab never needs a hunt for its button.
    @ViewBuilder
    private var closeButton: some View {
        if isSelected || isHovered {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: Self.accessoryWidth, height: Self.accessoryWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close Tab"))
        } else {
            Color.clear
        }
    }

    private static let accessoryWidth: CGFloat = 16
    private static let accessoryInset: CGFloat = 5
    private static let fontSize: CGFloat = 11
    private static let hoverFillOpacity: CGFloat = 0.5
    private static let separatorHeight: CGFloat = 18
}

private extension View {
    /// The track and the new-tab button are the system's subdued glass. Before glass existed the
    /// nearest equivalent is a material, which keeps the same read of a recess behind content.
    @ViewBuilder
    func trackGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            background(.regularMaterial, in: Capsule(style: .continuous))
        }
    }

    @ViewBuilder
    func tabGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        } else {
            background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
            )
        }
    }
}

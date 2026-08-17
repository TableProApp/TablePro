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
/// Glass is applied where the system applies it and nowhere else: the selected tab and the new-tab
/// button, which is the one pane the system slides along its track. The track carries no fill of
/// its own. The strip sits in the content view over plain window background rather than on toolbar
/// material, and an alpha fill lands at very different strength on the two appearances there:
/// `quaternarySystemFill` is a white wash over the dark chrome and a black one over the light
/// chrome, which in dark mode reads as a raised panel no other part of the window has.
internal struct EditorTabStrip: View {
    internal let tabManager: QueryTabManager
    internal let onClose: (UUID) -> Void
    internal let onCloseOthers: (UUID) -> Void
    internal let onCloseAll: () -> Void
    internal let onNewTab: () -> Void

    @State private var hoveredTabId: UUID?
    @Environment(\.controlActiveState) private var controlActiveState

    internal var body: some View {
        HStack(spacing: EditorTabStripLayout.trackSpacing) {
            track
            EditorTabStripNewButton(action: onNewTab, isWindowActive: isWindowActive)
        }
        .padding(EditorTabStripLayout.stripInset)
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive { hoveredTabId = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Editor Tabs"))
        .accessibilityAddTraits(.isTabBar)
    }

    private var track: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                            item(for: tab, at: index)
                                .frame(
                                    width: EditorTabStripLayout.tabWidth(
                                        forTrack: proxy.size.width,
                                        count: tabManager.tabs.count
                                    )
                                )
                                .id(tab.id)
                        }
                    }
                }
                /// Cmd+1..9, opening a table from the sidebar and closing a tab can all land on
                /// a tab that is scrolled out of sight, so the selection pulls itself into view.
                .onChange(of: tabManager.selectedTabId) { _, newValue in
                    guard let newValue else { return }
                    withMotion(.easeOut(duration: 0.15)) {
                        scroller.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .frame(height: EditorTabStripLayout.tabHeight)
            .padding(EditorTabStripLayout.trackPadding)
        }
        .frame(height: EditorTabStripLayout.trackHeight)
    }

    private func item(for tab: QueryTab, at index: Int) -> some View {
        EditorTabStripItem(
            tab: tab,
            isSelected: tabManager.selectedTab?.id == tab.id,
            isHovered: hoveredTabId == tab.id,
            isWindowActive: isWindowActive,
            showsLeadingSeparator: EditorTabStripLayout.showsSeparator(
                before: index,
                tabIds: tabManager.tabs.map(\.id),
                selectedId: tabManager.selectedTab?.id,
                hoveredId: hoveredTabId
            ),
            position: index + 1,
            count: tabManager.tabs.count,
            onHover: { hovering in
                if hovering {
                    hoveredTabId = tab.id
                } else if hoveredTabId == tab.id {
                    hoveredTabId = nil
                }
            },
            onSelect: { tabManager.selectedTabId = tab.id },
            onClose: { onClose(tab.id) },
            onCloseOthers: { onCloseOthers(tab.id) },
            onCloseAll: onCloseAll
        )
    }

    private var isWindowActive: Bool {
        controlActiveState != .inactive
    }
}

private struct EditorTabStripItem: View {
    let tab: QueryTab
    let isSelected: Bool
    let isHovered: Bool
    let isWindowActive: Bool
    let showsLeadingSeparator: Bool
    let position: Int
    let count: Int
    let onHover: (Bool) -> Void
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                if showsLeadingSeparator {
                    HStack {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 1, height: EditorTabStripLayout.separatorHeight)
                        Spacer()
                    }
                }

                background

                /// A spacer holds each end so the title stays optically centred. The close button
                /// sits in the leading one as a sibling overlay rather than inside this label,
                /// because a button nested in a button never receives the click.
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: EditorTabStripLayout.accessoryWidth)
                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .italic(tab.isPreview)
                        .font(.system(size: EditorTabStripLayout.fontSize))
                        .foregroundStyle(titleColor)
                        .frame(maxWidth: .infinity)
                    Color.clear
                        .frame(width: EditorTabStripLayout.accessoryWidth)
                }
                .padding(.horizontal, EditorTabStripLayout.accessoryInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            closeButton
                .padding(.leading, EditorTabStripLayout.accessoryInset)
        }
        .onHover(perform: onHover)
        .help(Text(tab.title))
        .contextMenu {
            Button(String(localized: "Close Tab"), action: onClose)
            Button(String(localized: "Close Other Tabs"), action: onCloseOthers)
            Button(String(localized: "Close All Tabs"), action: onCloseAll)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor-tab")
        .accessibilityLabel(Text(tab.title))
        .accessibilityValue(Text(positionDescription))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Close Tab"), onClose)
    }

    private var positionDescription: String {
        String(format: String(localized: "%1$d of %2$d"), position, count)
    }

    private var titleColor: Color {
        guard isWindowActive else {
            return Color(nsColor: isSelected ? .secondaryLabelColor : .tertiaryLabelColor)
        }
        return Color(nsColor: isSelected ? .labelColor : .secondaryLabelColor)
    }

    /// The selected tab is the one pane of glass the system raises out of the track. An
    /// unselected tab is not inert either: hovering fills it so the pointer has something to
    /// land on, and a background window shows neither.
    @ViewBuilder
    private var background: some View {
        if isSelected {
            Color.clear.selectedTabSurface(isLightAppearance: colorScheme == .light, isWindowActive: isWindowActive)
        } else if isHovered, isWindowActive {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
        }
    }

    /// Shown for the tab in front at all times, and for any tab the pointer is over, so closing
    /// the visible tab never needs a hunt for its button.
    @ViewBuilder
    private var closeButton: some View {
        if isSelected || (isHovered && isWindowActive) {
            EditorTabStripCloseButton(action: onClose, isWindowActive: isWindowActive)
        } else {
            Color.clear
        }
    }
}

private struct EditorTabStripCloseButton: View {
    let action: () -> Void
    let isWindowActive: Bool

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(nsColor: isWindowActive ? .secondaryLabelColor : .tertiaryLabelColor))
                .frame(
                    width: EditorTabStripLayout.accessoryWidth,
                    height: EditorTabStripLayout.accessoryWidth
                )
                .contentShape(Circle())
        }
        .buttonStyle(EditorTabStripCloseButtonStyle(isHovering: isHovering))
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text("Close Tab"))
    }
}

private struct EditorTabStripCloseButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle().fill(fill(isPressed: configuration.isPressed))
            )
    }

    private func fill(isPressed: Bool) -> Color {
        if isPressed { return Color(nsColor: .tertiarySystemFill) }
        return isHovering ? Color(nsColor: .quaternarySystemFill) : .clear
    }
}

private struct EditorTabStripNewButton: View {
    let action: () -> Void
    let isWindowActive: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: isWindowActive ? .secondaryLabelColor : .tertiaryLabelColor))
                .frame(
                    width: EditorTabStripLayout.newTabButtonSize,
                    height: EditorTabStripLayout.newTabButtonSize
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .newTabSurface(isLightAppearance: colorScheme == .light)
        .help(Text("New Tab"))
        .accessibilityLabel(Text("New Tab"))
    }
}

private extension View {
    /// Glass on macOS 26 and later, and the flat control fill that preceded it before that.
    /// `controlBackgroundColor` is not the fallback: it matches the window background exactly in
    /// dark mode, so the raised tab would read as a hole punched in its own track.
    @ViewBuilder
    func selectedTabSurface(isLightAppearance: Bool, isWindowActive: Bool) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: isWindowActive ? .controlColor : .unemphasizedSelectedContentBackgroundColor))
                    .shadow(
                        color: .black.opacity(isLightAppearance ? 0.12 : 0),
                        radius: isLightAppearance ? 1 : 0,
                        y: isLightAppearance ? 0.5 : 0
                    )
            )
        }
    }

    /// The one genuine press target in the strip, so this is where interactive glass belongs.
    /// The tab capsule does not take it: the tab a click lands on is an unselected one, which
    /// carries no glass to respond.
    @ViewBuilder
    func newTabSurface(isLightAppearance: Bool) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Circle())
        } else {
            background(
                Circle()
                    .fill(Color(nsColor: .controlColor))
                    .shadow(
                        color: .black.opacity(isLightAppearance ? 0.12 : 0),
                        radius: isLightAppearance ? 1 : 0,
                        y: isLightAppearance ? 0.5 : 0
                    )
            )
        }
    }
}

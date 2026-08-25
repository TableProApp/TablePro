//
//  EditorTabStrip.swift
//  TablePro
//

import SwiftUI
import UniformTypeIdentifiers

/// The editor tabs for one connection, drawn to the geometry of `NSTabBar`, the private control
/// the system's own window tab bar is built from. Native window tabs cannot express this: a window
/// belongs to exactly one tab group and a group's bar shows every window in it, so one window
/// hosting several connections could only ever show all of their tabs interleaved.
///
/// The band is a titlebar accessory rather than a row in the content stack, so this view draws
/// only what sits inside it: a filled track pinned to the band's top edge, and a new-tab button
/// outside the track. `EditorTabStripAccessoryController` owns the band itself.
///
/// The track carries a surface, which is the whole difference between a tab bar and three loose
/// pills. Without one the selected tab is a lone pane of glass over the content background, and
/// glass draws itself there as a control floating above content, with the drop shadow to match:
/// the tab ended up ringed in shadow where the system rings it in light. The two capsules are
/// concentric at their ends, the selected one inset two points inside the track, which is why it
/// never overruns the track's curve.
///
/// Track, selected tab and new-tab button are all glass, which is what the system does too, but
/// the track and the tab on it are not the same glass. Two `.regular` surfaces stacked carry no
/// step of their own, because each samples the backdrop under the window rather than the glass it
/// sits on, so the selection would be whatever the content behind the strip happened to be.
/// `EditorTabStripEmphasis` holds them apart, and carries the measurements that set the distance.
internal struct EditorTabStrip: View {
    internal let tabManager: QueryTabManager
    /// The dimension this engine's tabs are anchored to, so a label can name the container it
    /// shares a title with. Resolved by the window, because a view has no business asking the
    /// plugin registry what kind of container a connection has.
    internal let containerTarget: ContainerSwitchTarget?
    internal let onClose: (UUID) -> Void
    internal let onCloseOthers: (UUID) -> Void
    internal let onCloseAll: () -> Void
    internal let onNewTab: () -> Void
    /// Left unset by the app, which reads the two accessibility settings instead. A test sets it,
    /// because glass does not rasterise.
    internal var surfaceStyle: EditorTabStripSurfaceStyle?

    @State private var hoveredTabId: UUID?
    /// The tab under the pointer during a reorder. Held here rather than in the item, because the
    /// separators are a property of the row: they are hidden for the whole strip while a tab is in
    /// flight, so a line does not appear between two tabs that are mid-swap.
    @State private var draggingTabId: UUID?
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    internal var body: some View {
        glassContainer {
            HStack(spacing: EditorTabStripLayout.trackSpacing) {
                track
                EditorTabStripNewButton(
                    action: onNewTab,
                    isWindowActive: isWindowActive,
                    prefersSolidSurfaces: prefersSolidSurfaces
                )
            }
            .frame(height: EditorTabStripLayout.trackHeight)
        }
        .padding(.horizontal, EditorTabStripLayout.stripInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive { hoveredTabId = nil }
        }
        /// A closed tab leaves its id behind, and the tab that slides into its place would
        /// otherwise light up under a pointer that never moved onto it.
        .onChange(of: tabManager.tabs.map(\.id)) { _, ids in
            if let hoveredTabId, !ids.contains(hoveredTabId) { self.hoveredTabId = nil }
            if let draggingTabId, !ids.contains(draggingTabId) { self.draggingTabId = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Editor Tabs"))
        .accessibilityAddTraits(.isTabBar)
    }

    /// One container for every glass element in the strip. Glass cannot sample glass across
    /// containers, so the track, the selected tab and the new-tab button light inconsistently
    /// when they are not grouped, and the button sits only four points from the track's edge.
    ///
    /// `spacing` stays at zero. It is the proximity at which the container starts *merging*
    /// neighbouring shapes into one, and the new-tab button flowing into the track is not wanted.
    /// Note that grouping is not free: the container raises the glass it holds above the rest of
    /// its content, which is why every control the tabs draw has to live inside its own glass
    /// rather than beside it.
    @ViewBuilder
    private func glassContainer(@ViewBuilder content: () -> some View) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content() }
        } else {
            content()
        }
    }

    private var track: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                let labels = EditorTabLabelResolver.resolve(tabs: tabManager.tabs, target: containerTarget)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                            item(for: tab, at: index, label: labels[tab.id])
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
            /// Clipped to the same capsule the tabs are drawn as, so a tab scrolled under the
            /// track's rounded end is cut by that curve instead of squaring it off.
            .clipShape(Capsule(style: .continuous))
            .padding(EditorTabStripLayout.trackPadding)
        }
        .frame(height: EditorTabStripLayout.trackHeight)
        .trackSurface(prefersSolidSurfaces: prefersSolidSurfaces)
        .onDrop(of: [.text], delegate: EditorTabStripDropReset(draggingTabId: $draggingTabId))
    }

    private func item(
        for tab: QueryTab,
        at index: Int,
        label: EditorTabLabelResolver.Label?
    ) -> some View {
        EditorTabStripItem(
            tab: tab,
            label: label ?? EditorTabLabelResolver.Label(text: tab.title, description: tab.title),
            isSelected: tabManager.selectedTab?.id == tab.id,
            isHovered: hoveredTabId == tab.id,
            isWindowActive: isWindowActive,
            prefersSolidSurfaces: prefersSolidSurfaces,
            showsLeadingSeparator: EditorTabStripLayout.showsSeparator(
                before: index,
                tabIds: tabManager.tabs.map(\.id),
                selectedId: tabManager.selectedTab?.id,
                hoveredId: hoveredTabId,
                isReordering: draggingTabId != nil
            ),
            position: index + 1,
            count: tabManager.tabs.count,
            onHover: { hovering in
                if hovering {
                    hoveredTabId = tab.id
                    /// The one drag ending SwiftUI never reports is a cancel, so this is where a
                    /// strip left mid-reorder by Escape comes back.
                    draggingTabId = nil
                } else if hoveredTabId == tab.id {
                    hoveredTabId = nil
                }
            },
            onSelect: { tabManager.selectedTabId = tab.id },
            onClose: { onClose(tab.id) },
            onCloseOthers: { onCloseOthers(tab.id) },
            onCloseAll: onCloseAll,
            canMoveLeft: tabManager.canMoveTab(id: tab.id, by: -1),
            canMoveRight: tabManager.canMoveTab(id: tab.id, by: 1),
            onMoveLeft: { tabManager.moveTab(id: tab.id, by: -1) },
            onMoveRight: { tabManager.moveTab(id: tab.id, by: 1) }
        )
        .opacity(draggingTabId == tab.id ? EditorTabStripLayout.draggingOpacity : 1)
        .onDrag {
            draggingTabId = tab.id
            /// The id travels as text so a tab dragged onto anything else is inert rather than
            /// dropping a filename or a URL into it.
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: EditorTabDropDelegate(
                targetId: tab.id,
                draggingTabId: $draggingTabId,
                tabManager: tabManager
            )
        )
    }

    private var isWindowActive: Bool {
        controlActiveState != .inactive
    }

    /// One reader for the whole strip, so a track and the tab on it can never disagree about
    /// whether they are glass.
    private var prefersSolidSurfaces: Bool {
        if let surfaceStyle { return surfaceStyle == .solid }
        return EditorTabStripEmphasis.prefersSolidSurfaces(
            reduceTransparency: reduceTransparency,
            contrast: colorSchemeContrast
        )
    }
}

/// Reorders the strip as a tab is dragged over its neighbours, rather than waiting for the drop.
///
/// The swap happens in `dropEntered`, so the tabs move under the pointer the way the system's own
/// window tabs do. `performDrop` has nothing left to do but clear the drag, and returning true
/// there is what tells AppKit the drag was accepted rather than snapping the tab back.
private struct EditorTabDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var draggingTabId: UUID?
    let tabManager: QueryTabManager

    func dropEntered(info: DropInfo) {
        guard let draggingTabId, draggingTabId != targetId else { return }
        guard let destination = tabManager.tabs.firstIndex(where: { $0.id == targetId }) else { return }
        withMotion(.easeInOut(duration: 0.18)) {
            tabManager.moveTab(id: draggingTabId, to: destination)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingTabId = nil
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingTabId != nil
    }
}

/// Ends the reorder when the drag finishes anywhere that is not a tab.
///
/// `onDrag` reports no cancellation, so the drag state has to be cleared from whatever happens
/// next instead. Releasing over a gap in the track lands here, and leaving the track entirely fires
/// `dropExited`. The remaining case is a drag cancelled with Escape, which reports nothing at all;
/// the strip clears that on the next hover, because a pointer that cancelled a drag is still over
/// the strip and about to move.
private struct EditorTabStripDropReset: DropDelegate {
    @Binding var draggingTabId: UUID?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        draggingTabId = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingTabId = nil
        return true
    }
}

private struct EditorTabStripItem: View {
    let tab: QueryTab
    let label: EditorTabLabelResolver.Label
    let isSelected: Bool
    let isHovered: Bool
    let isWindowActive: Bool
    let prefersSolidSurfaces: Bool
    let showsLeadingSeparator: Bool
    let position: Int
    let count: Int
    let onHover: (Bool) -> Void
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void

    var body: some View {
        ZStack {
            if showsLeadingSeparator {
                HStack {
                    Rectangle()
                        .fill(EditorTabStripPalette.separator)
                        .frame(
                            width: EditorTabStripLayout.hairline,
                            height: EditorTabStripLayout.separatorHeight
                        )
                    Spacer()
                }
            }

            surface
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .help(Text(label.description))
        .contextMenu {
            Button(String(localized: "Close Tab"), action: onClose)
            Button(String(localized: "Close Other Tabs"), action: onCloseOthers)
            Button(String(localized: "Close All Tabs"), action: onCloseAll)
            Divider()
            /// Dragging is the usual way to reorder, and it is also the only way that needs a
            /// pointer. These give the same reordering to the keyboard and to VoiceOver, which
            /// reaches a context menu but cannot perform a drag.
            Button(String(localized: "Move Tab Left"), action: onMoveLeft)
                .disabled(!canMoveLeft)
            Button(String(localized: "Move Tab Right"), action: onMoveRight)
                .disabled(!canMoveRight)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("editor-tab")
        .accessibilityLabel(Text(label.text))
        .accessibilityValue(Text(positionDescription))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Close Tab"), onClose)
        .accessibilityAction(named: Text("Move Tab Left")) { if canMoveLeft { onMoveLeft() } }
        .accessibilityAction(named: Text("Move Tab Right")) { if canMoveRight { onMoveRight() } }
    }

    /// Everything the tab draws lives inside the glass, never over it. A `GlassEffectContainer`
    /// raises the glass it holds above the rest of that container's content, so a sibling drawn
    /// earlier in a `ZStack`, or an overlay attached outside, is painted over rather than under:
    /// the title first measured dimmer than every unselected one, and the close button vanished
    /// from the selected tab entirely.
    ///
    /// The two controls are siblings rather than nested, because a button inside another button's
    /// label never receives the click.
    private var surface: some View {
        ZStack {
            Button(action: onSelect) { title }
                .buttonStyle(.plain)

            HStack(spacing: 0) {
                closeButton
                Spacer(minLength: 0)
            }
            .padding(.leading, EditorTabStripLayout.accessoryInset)
        }
        .tabSurface(
            isSelected: isSelected,
            isHovered: isHovered,
            isWindowActive: isWindowActive,
            prefersSolidSurfaces: prefersSolidSurfaces
        )
    }

    /// A spacer holds each end so the title stays optically centred. The close button sits in the
    /// leading one as a sibling overlay rather than inside this label, because a button nested in
    /// a button never receives the click.
    private var title: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: EditorTabStripLayout.accessoryWidth)
            Text(label.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .italic(tab.isPreview)
                .font(.system(size: EditorTabStripLayout.fontSize))
                .foregroundStyle(titleColor)
                .frame(maxWidth: .infinity)
            unseenIndicator
                .frame(width: EditorTabStripLayout.accessoryWidth)
        }
        .padding(.horizontal, EditorTabStripLayout.accessoryInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        /// The whole tab is the target, not the glyphs. A `Button` hit-tests the shape its label
        /// draws, and this label is a short run of text between two clear spacers, so without a
        /// shape of its own everything either side of a title like "Album" stops selecting the
        /// tab: roughly 55pt of dead zone at each end of a 184pt tab.
        .contentShape(Rectangle())
    }

    /// Work that finished while this tab was not the one on screen. It sits in the trailing
    /// accessory slot the layout already reserves, so nothing reflows when it appears, and it
    /// never shows on the selected tab because selecting the tab is what clears it.
    @ViewBuilder
    private var unseenIndicator: some View {
        if tab.execution.finishedUnseenAt != nil, !isSelected {
            Circle()
                .fill(Color.accentColor)
                .frame(width: EditorTabStripLayout.unseenDotDiameter)
                .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }

    private var positionDescription: String {
        let place = String(format: String(localized: "%1$d of %2$d"), position, count)
        guard tab.execution.finishedUnseenAt != nil, !isSelected else { return place }
        return String(format: String(localized: "%@, finished"), place)
    }

    /// The system draws both labels in the same face at the same size and separates them by colour
    /// alone; measuring its bar shows identical glyph advances for a selected and an unselected
    /// title, so weight carries no meaning here.
    private var titleColor: Color {
        guard isWindowActive else {
            return Color(nsColor: isSelected ? .secondaryLabelColor : .tertiaryLabelColor)
        }
        return Color(nsColor: isSelected ? .labelColor : .secondaryLabelColor)
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
    let prefersSolidSurfaces: Bool

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
        .newTabSurface(isLightAppearance: colorScheme == .light, prefersSolidSurfaces: prefersSolidSurfaces)
        .help(Text("New Tab"))
        .accessibilityLabel(Text("New Tab"))
    }
}

private extension View {
    /// The track is a material, not a wash. Sampling the system's own bar against three different
    /// chrome colours shows it converging on a fixed tone rather than tinting whatever is behind
    /// it: about 78 percent opaque over rgb(77) in dark, and 85 percent over rgb(228) in light.
    /// `secondarySystemFill` is a white wash in dark and a black one in light, so it lands within a
    /// few points of the system in dark and inverts in light, a track darker than the titlebar it
    /// sits in.
    ///
    /// The tint is what makes it a *track* rather than a second pane at the same height as the tab
    /// on it. `EditorTabStripEmphasis` carries the measurements.
    ///
    /// The glass goes on the track's own content rather than behind it as a `.background`, because
    /// a `GlassEffectContainer` raises the glass it holds above the container's other content: a
    /// track drawn as a sibling layer paints over the tabs it is supposed to sit under.
    @ViewBuilder
    func trackSurface(prefersSolidSurfaces: Bool) -> some View {
        if #available(macOS 26.0, *), !prefersSolidSurfaces {
            glassEffect(.regular.tint(EditorTabStripEmphasis.trackTint), in: Capsule(style: .continuous))
        } else {
            background(
                Capsule(style: .continuous)
                    .fill(EditorTabStripPalette.trackFill)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                EditorTabStripPalette.trackEdge,
                                lineWidth: EditorTabStripLayout.hairline
                            )
                    )
            )
        }
    }

    /// The selected tab is the one pane of glass the system raises out of the track. An unselected
    /// tab is not inert either: hovering fills it so the pointer has something to land on, and a
    /// background window shows neither.
    @ViewBuilder
    func tabSurface(
        isSelected: Bool,
        isHovered: Bool,
        isWindowActive: Bool,
        prefersSolidSurfaces: Bool
    ) -> some View {
        if isSelected {
            selectedTabSurface(prefersSolidSurfaces: prefersSolidSurfaces)
        } else if isHovered, isWindowActive {
            background(Capsule(style: .continuous).fill(EditorTabStripPalette.hoverFill))
        } else {
            self
        }
    }

    /// Glass on macOS 26 and later, and the flat control fill that preceded it before that.
    /// `controlBackgroundColor` is not the fallback: it matches the window background exactly in
    /// dark mode, so the raised tab would read as a hole punched in its own track.
    ///
    /// The fill does not step down for a background window. Reaching for the track's own
    /// `unemphasizedSelectedContentBackgroundColor` there left the two identical, and the shadow
    /// that was supposed to cover for it was drawn in light alone and clipped away by the track's
    /// own 24pt capsule anyway, so a background window showed no selected tab at all. The system
    /// keeps its selected tab drawn in a background window; only the labels step down, which they
    /// already do in `titleColor`.
    ///
    /// The rim is the half of the selection that survives a background window on glass, where
    /// macOS attenuates the tint.
    @ViewBuilder
    func selectedTabSurface(prefersSolidSurfaces: Bool) -> some View {
        if #available(macOS 26.0, *), !prefersSolidSurfaces {
            glassEffect(.regular.tint(EditorTabStripEmphasis.selectionTint), in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            EditorTabStripEmphasis.selectionEdge,
                            lineWidth: EditorTabStripEmphasis.selectionEdgeWidth
                        )
                )
        } else {
            background(Capsule(style: .continuous).fill(EditorTabStripPalette.selectedFill))
        }
    }

    /// The one genuine press target in the strip, so this is where interactive glass belongs.
    /// The tab capsule does not take it: the tab a click lands on is an unselected one, which
    /// carries no glass to respond.
    ///
    /// It keeps the untinted material on purpose. The button sits outside the track, so it belongs
    /// at the height of the chrome rather than recessed into a channel it is not in.
    @ViewBuilder
    func newTabSurface(isLightAppearance: Bool, prefersSolidSurfaces: Bool) -> some View {
        if #available(macOS 26.0, *), !prefersSolidSurfaces {
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

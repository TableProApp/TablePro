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
/// The track and the selected tab are opaque fills, and only the new-tab button is
/// glass. A selection cannot be drawn in glass, because glass takes its colour from whatever is
/// behind the window and a selection has to mean the same thing over every wallpaper. Measured
/// across twenty arrangements on macOS 27, every glass surface nested in, beside, or unioned with
/// another one rendered *darker* than its track in light appearance, and the pair that shipped
/// inverted again whenever the window lost key. That is also what Apple asks for: "avoid applying
/// the material to both layers. Instead, use fills, transparency, and vibrancy for the top
/// elements" (WWDC25 session 219). The band is already the system's glass, so these fills are the
/// top layer on it rather than a second pane of it.
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
    /// The tab the previous click activated, so the second click of a double-click can be told
    /// from a click on a neighbour that happened to land inside the double-click window.
    @State private var lastActivatedTabId: UUID?
    /// A tab whose selection came from a click on the tab itself, which must not be recentred.
    /// The track scrolls once the tabs stop fitting, and sliding the clicked tab to the middle
    /// takes it out from under a second click that is already on its way.
    @State private var clickSelectedTabId: UUID?
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
            if let lastActivatedTabId, !ids.contains(lastActivatedTabId) { self.lastActivatedTabId = nil }
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
                    guard clickSelectedTabId != newValue else {
                        clickSelectedTabId = nil
                        return
                    }
                    withMotion(.easeOut(duration: 0.15)) {
                        scroller.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .frame(height: EditorTabStripLayout.tabHeight)
            /// Clipped to the same shape the tabs are drawn as, so a tab scrolled under the
            /// track's rounded end is cut by that curve instead of squaring it off.
            .clipShape(EditorTabStripLayout.tabShape)
            .padding(EditorTabStripLayout.trackPadding)
        }
        .frame(height: EditorTabStripLayout.trackHeight)
        .trackSurface()
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
            onActivate: { activate(tab.id) },
            onClose: { onClose(tab.id) },
            onCloseOthers: { onCloseOthers(tab.id) },
            onCloseAll: onCloseAll,
            canKeepOpen: tabManager.canPromotePreviewTab(id: tab.id),
            onKeepOpen: { tabManager.promotePreviewTab(id: tab.id) },
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

    /// Selects the tab, and keeps it when the click that got here was the second of a double-click.
    ///
    /// The click count is read off the event AppKit is currently dispatching rather than arbitrated
    /// by a SwiftUI gesture, which is what `NSTableView` does with `action` and `doubleAction`.
    /// Measured against the shipping strip: a `TapGesture(count: 2)` in any composition holds the
    /// selection back 371ms on every click and drops it entirely on the double, and a
    /// `simultaneousGesture` selects twice; reading the event costs the same 22ms as selecting.
    private func activate(_ tabId: UUID) {
        let activation = EditorTabActivationResolver.resolve(
            click: EditorTabClick(event: NSApp.currentEvent),
            tabId: tabId,
            lastActivatedTabId: lastActivatedTabId
        )
        lastActivatedTabId = tabId
        /// Set only when the selection is about to change, so the flag is always consumed by the
        /// `onChange` it is meant for rather than left behind to swallow a later Cmd+1.
        if tabManager.selectedTabId != tabId {
            clickSelectedTabId = tabId
        }
        tabManager.selectedTabId = tabId
        guard activation == .selectAndKeep else { return }
        tabManager.promotePreviewTab(id: tabId)
    }

    private var isWindowActive: Bool {
        controlActiveState != .inactive
    }

    /// Read only by the new-tab button now, which is the one surface still allowed to be glass.
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
    let showsLeadingSeparator: Bool
    let position: Int
    let count: Int
    let onHover: (Bool) -> Void
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void
    let canKeepOpen: Bool
    let onKeepOpen: () -> Void
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
        .help(Text(tooltip))
        .contextMenu {
            /// The double-click that keeps a tab is an editor idiom rather than a system one, so
            /// it needs a command beside it: a gesture with no menu equivalent cannot be found by
            /// a user who does not already expect it, and cannot be performed at all by VoiceOver.
            Button(String(localized: "Keep Open"), action: onKeepOpen)
                .disabled(!canKeepOpen)
            Divider()
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
        /// Offered only where it does something, so the actions rotor matches the contextual menu
        /// rather than announcing a command that silently does nothing on a tab already kept.
        .accessibilityActions {
            if canKeepOpen {
                Button(String(localized: "Keep Open"), action: onKeepOpen)
            }
        }
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
            Button(action: onActivate) { title }
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
            isWindowActive: isWindowActive
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

    /// Carries the preview state, because the italic title cannot: an assistive technology is told
    /// the string, never the face it is set in, and the HIG asks that no interface rely on a single
    /// method to convey a change in state.
    private var positionDescription: String {
        var description = String(format: String(localized: "%1$d of %2$d"), position, count)
        if tab.isPreview {
            description = String(format: String(localized: "%@, preview tab"), description)
        }
        guard tab.execution.finishedUnseenAt != nil, !isSelected else { return description }
        return String(format: String(localized: "%@, finished"), description)
    }

    /// The pointer's route to the same state the title's italic carries, and the only place the
    /// gesture that keeps the tab is named outside the context menu.
    private var tooltip: String {
        guard tab.isPreview else { return label.description }
        return String(
            format: String(localized: "%@\nPreview tab. Double-click to keep it open."),
            label.description
        )
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
    /// An opaque tone rather than a wash, for the same reason the system's own track is one: a
    /// wash tints whatever is behind it, and the track has to stay below the selected tab whatever
    /// that happens to be. The system's own tab bar measures a track of rgb(232) in light against
    /// this fill's rgb(220), and rgb(71) in dark against this fill's rgb(70).
    func trackSurface() -> some View {
        background(
            EditorTabStripLayout.trackShape
                .fill(EditorTabStripPalette.trackFill)
                .overlay(
                    EditorTabStripLayout.trackShape
                        .strokeBorder(
                            EditorTabStripPalette.trackEdge,
                            lineWidth: EditorTabStripLayout.hairline
                        )
                )
        )
    }

    /// The selected tab is the one pane of glass the system raises out of the track. An unselected
    /// tab is not inert either: hovering fills it so the pointer has something to land on, and a
    /// background window shows neither.
    @ViewBuilder
    func tabSurface(
        isSelected: Bool,
        isHovered: Bool,
        isWindowActive: Bool
    ) -> some View {
        if isSelected {
            selectedTabSurface()
        } else if isHovered, isWindowActive {
            background(EditorTabStripLayout.tabShape.fill(EditorTabStripPalette.hoverFill))
        } else {
            self
        }
    }

    /// A fill and a rim, which is how the system draws a raised segment. A vertical section
    /// through a selected segment reads track 236, rim 215, highlight 255, body 242: the fill
    /// carries six levels and the edge carries twenty-one. Only the fill was drawn here before,
    /// which is why the selection read as flat even at the distance the system uses.
    ///
    /// `controlBackgroundColor` is not the fill: it matches the window background exactly in dark,
    /// so the raised tab would read as a hole punched in its own track.
    ///
    /// The fill does not step down for a background window. Reaching for the track's own
    /// `unemphasizedSelectedContentBackgroundColor` there left the two identical, so a background
    /// window showed no selected tab at all. The system keeps its selected tab drawn there; only
    /// the labels step down, which they already do in `titleColor`.
    func selectedTabSurface() -> some View {
        background(
            EditorTabStripLayout.tabShape
                .fill(EditorTabStripPalette.selectedFill)
                .overlay(
                    EditorTabStripLayout.tabShape
                        .strokeBorder(
                            EditorTabStripPalette.selectionEdge,
                            lineWidth: EditorTabStripLayout.hairline
                        )
                )
        )
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

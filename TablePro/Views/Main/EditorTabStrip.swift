//
//  EditorTabStrip.swift
//  TablePro
//

import SwiftUI

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
    /// The pointer's owner. AppKit measures the run and drives every press; this view draws what
    /// that produced. Nothing here reads a mouse.
    internal let interaction: EditorTabStripInteraction
    /// The dimension this engine's tabs are anchored to, so a label can name the container it
    /// shares a title with. Resolved by the window, because a view has no business asking the
    /// plugin registry what kind of container a connection has.
    internal let containerTarget: ContainerSwitchTarget?
    internal let onNewTab: () -> Void
    /// Left unset by the app, which reads the two accessibility settings instead. A test sets it,
    /// because glass does not rasterise.
    internal var surfaceStyle: EditorTabStripSurfaceStyle?

    /// Read here rather than pushed in at build time, so changing the preference re-lays every
    /// open strip at once instead of the next time an unrelated pane happens to rebuild.
    @State private var settings = AppSettingsManager.shared

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
                .frame(height: EditorTabStripLayout.trackHeight)
            }
            .frame(height: trackHeight, alignment: .top)
        }
        .padding(.horizontal, EditorTabStripLayout.stripInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        /// A closed tab leaves its id behind, and the tab that slides into its place would
        /// otherwise light up under a pointer that never moved onto it.
        .onChange(of: tabManager.tabs.map(\.id), initial: true) { _, ids in
            interaction.dropClosedTabs(keeping: ids)
        }
        .onChange(of: settings.tabs.overflow, initial: true) { _, style in
            interaction.overflow = style
        }
        /// Cmd+1..9, opening a table from the sidebar and closing a tab can all land on a tab that
        /// is scrolled out of sight, so the selection pulls itself into view.
        .onChange(of: tabManager.selectedTabId) { _, newValue in
            guard let newValue else { return }
            withMotion(.easeOut(duration: 0.15)) {
                interaction.revealTab(id: newValue)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Editor Tabs"))
        .accessibilityAddTraits(.isTabBar)
    }

    private var trackHeight: CGFloat {
        EditorTabStripLayout.trackHeight(forRowCount: interaction.run.rowCount)
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

    /// The tabs, each drawn at the rectangle `EditorTabRunLayout` gave it, shifted by however far
    /// the track has scrolled. There is no `ScrollView` here on purpose: the view that owns the
    /// press owns the wheel and the autoscroll too, so one object decides where a tab is and the
    /// drawing follows it rather than the two agreeing by construction.
    private var track: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(displayedTabs.enumerated()), id: \.element.id) { index, tab in
                item(for: tab, at: index, in: displayedTabs, label: labels[tab.id])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        /// Clipped to the same shape the track is drawn as, so a tab scrolled under a rounded end
        /// is cut by that curve instead of squaring it off. A capsule only stays right for one
        /// row: its radius is half the height, so a wrapped track would curve away most of the
        /// first row's close target while the pointer still hit-tests the whole rectangle.
        .clipShape(EditorTabStripLayout.trackShape(forRowCount: interaction.run.rowCount))
        .padding(EditorTabStripLayout.trackPadding)
        .frame(height: trackHeight)
        .trackSurface(rowCount: interaction.run.rowCount)
    }

    private var displayedTabs: [QueryTab] {
        let byId = Dictionary(tabManager.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return interaction.displayedIds.compactMap { byId[$0] }
    }

    private var labels: [UUID: EditorTabLabelResolver.Label] {
        EditorTabLabelResolver.resolve(tabs: displayedTabs, target: containerTarget)
    }

    @ViewBuilder
    private func item(
        for tab: QueryTab,
        at index: Int,
        in tabs: [QueryTab],
        label: EditorTabLabelResolver.Label?
    ) -> some View {
        if let placement = interaction.run.placement(at: index) {
            EditorTabStripItem(
                tab: tab,
                label: label ?? EditorTabLabelResolver.Label(text: tab.title, description: tab.title),
                isSelected: tabManager.selectedTab?.id == tab.id,
                isHovered: interaction.hoveredTabId == tab.id,
                isCloseHovered: interaction.hoveredCloseTabId == tab.id,
                isWindowActive: isWindowActive,
                showsLeadingSeparator: EditorTabStripLayout.showsSeparator(
                    before: index,
                    tabIds: tabs.map(\.id),
                    selectedId: tabManager.selectedTab?.id,
                    hoveredId: interaction.hoveredTabId,
                    isReordering: interaction.reorder != nil
                ),
                position: index + 1,
                count: tabs.count,
                commands: interaction.commands
            )
            .opacity(opacity(of: tab))
            .frame(width: placement.frame.width, height: placement.frame.height)
            .offset(
                x: placement.frame.minX - interaction.contentOffset,
                y: placement.frame.minY
            )
        }
    }

    /// The dragged tab fades enough to read as lifted out of the strip, and a tab being torn off
    /// fades further so the gesture says what it is about to do before the mouse comes up.
    private func opacity(of tab: QueryTab) -> CGFloat {
        if interaction.tearingOffTabId == tab.id { return EditorTabStripLayout.tearingOffOpacity }
        return interaction.reorder?.draggedId == tab.id ? EditorTabStripLayout.draggingOpacity : 1
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

private struct EditorTabStripItem: View {
    let tab: QueryTab
    let label: EditorTabLabelResolver.Label
    let isSelected: Bool
    let isHovered: Bool
    let isCloseHovered: Bool
    let isWindowActive: Bool
    let showsLeadingSeparator: Bool
    let position: Int
    let count: Int
    /// The same command set the pointer's owner drives. The controls below never receive a mouse
    /// event any more, and exist for the keyboard, Full Keyboard Access and VoiceOver, which reach
    /// them without one.
    let commands: EditorTabCommands?

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
        .contextMenu {
            /// The double-click that keeps a tab is an editor idiom rather than a system one, so
            /// it needs a command beside it: a gesture with no menu equivalent cannot be found by
            /// a user who does not already expect it, and cannot be performed at all by VoiceOver.
            Button(String(localized: "Keep Open")) { commands?.keepOpen(tab.id) }
                .disabled(!canKeepOpen)
            Divider()
            Button(String(localized: "Close Tab")) { commands?.close(tab.id) }
            Button(String(localized: "Close Other Tabs")) { commands?.closeOthers(tab.id) }
            Button(String(localized: "Close All Tabs")) { commands?.closeAll() }
            Divider()
            /// Dragging is the usual way to reorder, and it is also the only way that needs a
            /// pointer. These give the same reordering to the keyboard and to VoiceOver, which
            /// reaches a context menu but cannot perform a drag.
            Button(String(localized: "Move Tab Left")) { commands?.moveBy(tab.id, -1) }
                .disabled(!canMoveLeft)
            Button(String(localized: "Move Tab Right")) { commands?.moveBy(tab.id, 1) }
                .disabled(!canMoveRight)
            Divider()
            Button(String(localized: "Move Tab to New Window")) { commands?.tearOff(tab.id) }
                .disabled(!canTearOff)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("editor-tab")
        .accessibilityLabel(Text(label.text))
        .accessibilityValue(Text(positionDescription))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Close Tab")) { commands?.close(tab.id) }
        /// Offered only where it does something, so the actions rotor matches the contextual menu
        /// rather than announcing a command that silently does nothing on a tab already kept.
        .accessibilityActions {
            if canKeepOpen {
                Button(String(localized: "Keep Open")) { commands?.keepOpen(tab.id) }
            }
        }
        .accessibilityAction(named: Text("Move Tab Left")) { if canMoveLeft { commands?.moveBy(tab.id, -1) } }
        .accessibilityAction(named: Text("Move Tab Right")) { if canMoveRight { commands?.moveBy(tab.id, 1) } }
        .accessibilityAction(named: Text("Move Tab to New Window")) { if canTearOff { commands?.tearOff(tab.id) } }
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
            Button { commands?.activate(tab.id) } label: { title }
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
    private var canKeepOpen: Bool {
        commands?.canKeepOpen(tab.id) ?? false
    }

    private var canTearOff: Bool {
        commands?.canTearOff(tab.id) ?? false
    }

    private var canMoveLeft: Bool {
        commands?.canMove(tab.id, -1) ?? false
    }

    private var canMoveRight: Bool {
        commands?.canMove(tab.id, 1) ?? false
    }

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
            EditorTabStripCloseButton(
                action: { commands?.close(tab.id) },
                isHovering: isCloseHovered,
                isWindowActive: isWindowActive
            )
        } else {
            Color.clear
        }
    }
}

private struct EditorTabStripCloseButton: View {
    let action: () -> Void
    /// Driven by the view that owns the pointer, because this button no longer receives a mouse
    /// event of its own.
    let isHovering: Bool
    let isWindowActive: Bool

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
    func trackSurface(rowCount: Int) -> some View {
        let shape = EditorTabStripLayout.trackShape(forRowCount: rowCount)
        return background(
            shape
                .fill(EditorTabStripPalette.trackFill)
                .overlay(
                    shape
                        .stroke(
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

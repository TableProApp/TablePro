//
//  TrailingPaneHeaderView.swift
//  TablePro
//

import SwiftUI

/// One height for the header on every surface, so switching surface moves nothing beneath it.
///
/// Fixed rather than grown from padding, because the leading slot is a picker on one surface and a
/// title on another and the two are not the same height: measured on macOS 27, the small segmented
/// control is 20pt and a headline 18pt, beside a menu whose hit target is 22pt. Grown from its
/// content, the header changed height with the surface, which is the jump this view exists to remove.
internal enum TrailingPaneHeaderMetrics {
    internal static let height: CGFloat = 30
}

/// The trailing pane's header, drawn by each surface at its own top.
///
/// A picker between the surfaces the user may choose, or the surface's name where there is nothing to
/// choose, and one menu of that surface's commands. `TrailingPaneHeaderModel` decides all of it, so
/// the three surfaces cannot draw it three ways again; this view only draws what the model says, and
/// each surface supplies the commands in the menu sections the model names.
internal struct TrailingPaneHeaderView<MenuSectionContent: View>: View {
    private let surface: TrailingPaneSurface
    private let contentMode: ConnectionWorkspaceContentMode
    private let paneState: TrailingPaneState?
    private let inspectorRendering: InspectorViewMode?
    private let hasContent: Bool
    private let menuSection: (TrailingPaneMenuSection) -> MenuSectionContent

    /// Read live rather than captured when the pane was built. Turning the assistant off changes
    /// nothing the pane's render key holds while browsing, so a captured value would go on offering
    /// the assistant's segment over a pane that can no longer draw it.
    @ObservedObject private var settings = AppSettingsManager.shared

    /// `paneState` is nil for the result column, whose surface the mode chose, and for a connection
    /// whose session went and took its pane state with it. Either way there is no stored surface to
    /// write, so the header names its surface instead of offering a picker that could not answer.
    internal init(
        surface: TrailingPaneSurface,
        contentMode: ConnectionWorkspaceContentMode,
        paneState: TrailingPaneState?,
        inspectorRendering: InspectorViewMode? = nil,
        hasContent: Bool = true,
        @ViewBuilder menuSection: @escaping (TrailingPaneMenuSection) -> MenuSectionContent
    ) {
        self.surface = surface
        self.contentMode = contentMode
        self.paneState = paneState
        self.inspectorRendering = inspectorRendering
        self.hasContent = hasContent
        self.menuSection = menuSection
    }

    private var model: TrailingPaneHeaderModel {
        TrailingPaneHeaderModel(
            surface: surface,
            contentMode: contentMode,
            isAIEnabled: settings.ai.enabled,
            inspectorRendering: inspectorRendering,
            hasContent: hasContent
        )
    }

    internal var body: some View {
        let model = self.model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                leading(model)
                Spacer(minLength: 8)
                if !model.menuSections.isEmpty {
                    menu(model)
                }
            }
            .padding(.horizontal, InspectorMetrics.horizontalInset)
            .frame(height: TrailingPaneHeaderMetrics.height)
            Divider()
        }
    }

    @ViewBuilder
    private func leading(_ model: TrailingPaneHeaderModel) -> some View {
        if model.showsPicker, let paneState {
            TrailingPaneSurfacePicker(state: paneState, segments: model.segments)
        } else {
            Text(model.title)
                .font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The ellipsis draws no text, so the only name VoiceOver has for this control is the one the
    /// accessibility modifiers give it, and it takes all three of them.
    ///
    /// Measured on macOS 27, naming it through the label does not work in any arrangement. A `Label`
    /// whose title `.labelStyle(.iconOnly)` has resolved away carries no name, whichever view the
    /// style sits on, and `.accessibilityLabel` inside the label closure, which is how
    /// `ResultSetMenu` names a pull-down that also draws text, does not reach this one either.
    /// `.accessibilityLabel` on the `Menu` alone is likewise ignored. In all three the control falls
    /// back to AppKit's own name for an unnamed pull-down, which reads "More" locally and the empty
    /// string on the CI runner. Only `.accessibilityElement` publishes the name, and it has to be
    /// `.contain`: `.ignore` names the button and then takes the menu's own items out of the tree
    /// with it, so nothing can reach Fields, JSON or any other command in it.
    private func menu(_ model: TrailingPaneHeaderModel) -> some View {
        Menu {
            ForEach(Array(model.menuSections.enumerated()), id: \.element) { index, section in
                if index > 0 {
                    Divider()
                }
                menuSection(section)
            }
        } label: {
            Label(model.menuLabel, systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.subheadline)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 22)
        .help(model.menuLabel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.menuLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("trailing-pane-menu")
    }
}

/// The surface picker, observing the connection's pane state itself so that the segment it draws is
/// the surface the controller parents next rather than the one the pane was built with.
private struct TrailingPaneSurfacePicker: View {
    @ObservedObject var state: TrailingPaneState
    let segments: [TrailingPaneSurface]

    var body: some View {
        Picker(String(localized: "Pane"), selection: selection) {
            ForEach(segments, id: \.self) { segment in
                Self.symbol(for: segment)
                    .help(segment.localizedTitle)
                    .tag(segment)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .accessibilityIdentifier("trailing-pane-surface")
    }

    /// The segment's name travels in the symbol image's own description. Measured on macOS 27, a
    /// segmented picker names each segment from the image it was handed and never reads
    /// `.accessibilityLabel` on the view, so `Image(systemName:)` published "info" and "sparkle" to
    /// VoiceOver whatever label it carried. The image is the same template at the same size.
    private static func symbol(for segment: TrailingPaneSurface) -> Image {
        guard let image = NSImage(
            systemSymbolName: segment.symbolName,
            accessibilityDescription: segment.localizedTitle
        ) else {
            return Image(systemName: segment.symbolName)
        }
        return Image(nsImage: image)
    }

    /// Writes the stored surface and nothing else. A segment is a choice the user made, so it is
    /// remembered for the connection, which a suggestion such as a grid click never is. The controller
    /// watches the state of the connection on screen and parents the new surface on the next turn of
    /// the run loop, so the view whose segment was clicked leaves the window after its action has
    /// returned rather than from inside it.
    private var selection: Binding<TrailingPaneSurface> {
        Binding(
            get: { state.surface },
            set: { surface in
                guard surface.isUserSelectable else { return }
                state.surface = surface
            }
        )
    }
}

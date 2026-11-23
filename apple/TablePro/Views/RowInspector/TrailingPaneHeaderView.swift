import SwiftUI

// Fixed, not grown from content: the picker, a headline and the menu differ in height, and the header jumped with the surface.
internal enum TrailingPaneHeaderMetrics {
    internal static let height: CGFloat = 30
}

// `TrailingPaneHeaderModel` decides the picker, title and menu, so the three surfaces cannot draw it three ways.
internal struct TrailingPaneHeaderView<MenuSectionContent: View>: View {
    private let surface: TrailingPaneSurface
    private let contentMode: ConnectionWorkspaceContentMode
    private let paneState: TrailingPaneState?
    private let inspectorRendering: InspectorViewMode?
    private let hasContent: Bool
    private let menuSection: (TrailingPaneMenuSection) -> MenuSectionContent

    // Live: turning the assistant off changes nothing the pane's render key holds while browsing.
    @ObservedObject private var aiSettings = AppSettingsManager.shared.aiSlice

    // `paneState` is nil for the result column and for a session that went; there is no stored surface to write.
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
            isAIEnabled: aiSettings.value.enabled,
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

    // Only `.accessibilityElement(children: .contain)` publishes the name here; label-based naming is ignored on macOS 27.
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

// Observes the pane state itself, so the segment is the surface the controller parents next.
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
        .viewSwitcherStyle()
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("trailing-pane-surface")
    }

    // A segmented picker names each segment from its image and never reads `.accessibilityLabel`.
    private static func symbol(for segment: TrailingPaneSurface) -> Image {
        guard let image = NSImage(
            systemSymbolName: segment.symbolName,
            accessibilityDescription: segment.localizedTitle
        ) else {
            return Image(systemName: segment.symbolName)
        }
        return Image(nsImage: image)
    }

    // Writes the stored surface only; the controller parents it a turn later, after this action returns.
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

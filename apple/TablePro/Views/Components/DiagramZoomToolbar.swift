//
//  DiagramZoomToolbar.swift
//  TablePro
//
//  The floating zoom cluster both diagrams share. Extra controls are supplied per diagram.
//

import SwiftUI

struct DiagramZoomToolbar<Extras: View>: View {
    /// Observed here rather than trusted to a parent. The percentage and both buttons' enabled
    /// state are read from it in this body, and the plan diagram holds its viewport as a plain
    /// property, so on a plan every zoom changed the canvas and left the readout on the old
    /// percentage with Zoom In and Zoom Out dimmed as they were. The ER diagram hid it only because
    /// its own toolbar happens to observe the same object and redraws this one along with it.
    @ObservedObject var viewport: DiagramViewportController
    @ViewBuilder let extras: () -> Extras

    init(viewport: DiagramViewportController, @ViewBuilder extras: @escaping () -> Extras = { EmptyView() }) {
        self.viewport = viewport
        self.extras = extras
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: viewport.zoomOut) {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(!viewport.canZoomOut)
            .accessibilityLabel(String(localized: "Zoom Out"))
            .help(String(localized: "Zoom Out"))

            Button(action: viewport.resetZoom) {
                Text(verbatim: zoomPercentage)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 40)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Reset Zoom"))
            .accessibilityValue(Text(verbatim: zoomPercentage))
            .help(String(localized: "Reset Zoom"))

            Button(action: viewport.zoomIn) {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(!viewport.canZoomIn)
            .accessibilityLabel(String(localized: "Zoom In"))
            .help(String(localized: "Zoom In"))

            Button(action: viewport.fitToWindow) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel(String(localized: "Fit to Window"))
            .help(String(localized: "Fit to Window"))

            extras()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(DiagramZoomSurface())
    }

    private var zoomPercentage: String {
        "\(Int((viewport.magnification * 100).rounded()))%"
    }
}

/// Controls floating over content take Liquid Glass from macOS 26, as the Open Quickly panel and
/// the chat's jump button already do. Glass draws its own edge and adapts to Reduce Transparency
/// and Increase Contrast itself, so the hairline and the solid fallback belong to the material
/// only.
private struct DiagramZoomSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .themeMaterial(.toolbar, .thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        }
    }
}

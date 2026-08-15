//
//  DiagramZoomToolbar.swift
//  TablePro
//
//  The floating zoom cluster both diagrams share. Extra controls are supplied per diagram.
//

import SwiftUI

struct DiagramZoomToolbar<Extras: View>: View {
    let viewport: DiagramViewportController
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
            .accessibilityLabel(String(localized: "Zoom Out"))
            .help(String(localized: "Zoom Out"))

            Button(action: viewport.resetZoom) {
                Text(verbatim: "\(Int((viewport.magnification * 100).rounded()))%")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 40)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Reset Zoom"))
            .help(String(localized: "Reset Zoom"))

            Button(action: viewport.zoomIn) {
                Image(systemName: "plus.magnifyingglass")
            }
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
        .themeMaterial(.toolbar, .thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
    }
}

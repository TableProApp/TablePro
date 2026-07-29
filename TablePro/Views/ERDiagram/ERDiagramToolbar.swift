import SwiftUI

struct ERDiagramToolbar: View {
    @Bindable var viewModel: ERDiagramViewModel
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.zoom(to: viewModel.magnification - 0.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Zoom Out"))

            Button {
                viewModel.zoom(to: 1.0)
            } label: {
                Text(verbatim: "\(Int(viewModel.magnification * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 40)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Reset Zoom"))

            Button {
                viewModel.zoom(to: viewModel.magnification + 0.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Zoom In"))

            Button {
                viewModel.fitToWindow()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Fit to Window"))
            .help(String(localized: "Fit to Window"))

            Divider().frame(height: 16)

            Toggle(isOn: $viewModel.isCompactMode) {
                Image(systemName: "rectangle.compress.vertical")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(String(localized: "Compact Mode"))
            .accessibilityLabel(String(localized: "Compact Mode"))

            if viewModel.hasJunctionTables {
                Toggle(isOn: $viewModel.collapseJunctions) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(String(localized: "Collapse junction tables into many-to-many relationships"))
                .accessibilityLabel(String(localized: "Collapse Junction Tables"))
            }

            Divider().frame(height: 16)

            Button {
                viewModel.resetLayout()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Reset Layout"))
            .accessibilityLabel(String(localized: "Reset Layout"))

            Button(action: onExport) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Export as PNG"))
            .accessibilityLabel(String(localized: "Export as PNG"))

            Button {
                viewModel.exportSchemaAsSQL()
            } label: {
                Image(systemName: "doc.plaintext")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Export as SQL"))
            .accessibilityLabel(String(localized: "Export as SQL"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .themeMaterial(.toolbar, .thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .padding(12)
    }
}

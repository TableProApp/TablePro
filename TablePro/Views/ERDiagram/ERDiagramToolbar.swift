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
                Text("\(Int(viewModel.magnification * 100))%")
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .padding(12)
    }
}

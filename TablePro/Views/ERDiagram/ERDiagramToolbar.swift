import SwiftUI

struct ERDiagramToolbar: View {
    @Bindable var viewModel: ERDiagramViewModel
    let viewport: DiagramViewportController
    let onExport: () -> Void

    var body: some View {
        DiagramZoomToolbar(viewport: viewport) {
            Divider().frame(height: 16)

            Toggle(isOn: $viewModel.isCompactMode) {
                Image(systemName: "rectangle.compress.vertical")
            }
            .toggleStyle(.button)
            .help(String(localized: "Compact Mode"))
            .accessibilityLabel(String(localized: "Compact Mode"))

            if viewModel.hasJunctionTables {
                Toggle(isOn: $viewModel.collapseJunctions) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .toggleStyle(.button)
                .help(String(localized: "Collapse junction tables into many-to-many relationships"))
                .accessibilityLabel(String(localized: "Collapse Junction Tables"))
            }

            Divider().frame(height: 16)

            Button {
                viewModel.resetLayout()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help(String(localized: "Reset Layout"))
            .accessibilityLabel(String(localized: "Reset Layout"))

            Button(action: onExport) {
                Image(systemName: "square.and.arrow.up")
            }
            .help(String(localized: "Export as PNG"))
            .accessibilityLabel(String(localized: "Export as PNG"))

            Button {
                viewModel.exportSchemaAsSQL()
            } label: {
                Image(systemName: "doc.plaintext")
            }
            .help(String(localized: "Export as SQL"))
            .accessibilityLabel(String(localized: "Export as SQL"))
        }
        .padding(12)
    }
}

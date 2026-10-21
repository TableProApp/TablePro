import SwiftUI

struct ERDiagramToolbar: View {
    @ObservedObject var viewModel: ERDiagramViewModel
    @ObservedObject var viewport: DiagramViewportController
    let onExport: (ERDiagramExportFormat) -> Void
    let onCopyMermaid: () -> Void
    var onBuildJoinQuery: (() -> Void)?

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

            if let onBuildJoinQuery {
                Button(action: onBuildJoinQuery) {
                    Image(systemName: "arrow.triangle.merge")
                }
                .help(String(localized: "Build a join query from the selected tables"))
                .accessibilityLabel(String(localized: "Build Join Query"))
                .accessibilityIdentifier("er-diagram-build-join")
            }

            exportMenu
        }
        .padding(12)
    }

    // Only `.contain` names an icon-only menu without hiding its items.
    private var exportMenu: some View {
        Menu {
            ForEach(ERDiagramExportFormat.allCases) { format in
                Button {
                    onExport(format)
                } label: {
                    Text(verbatim: "\(format.name)\u{2026}")
                }
            }
            Divider()
            Button(String(localized: "Copy as Mermaid"), action: onCopyMermaid)
        } label: {
            Label(String(localized: "Export"), systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Export"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Export"))
        .accessibilityIdentifier("er-diagram-export")
    }
}

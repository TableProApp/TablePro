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

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(viewModel.isRefreshing)
            .help(String(localized: "Refresh"))
            .accessibilityLabel(String(localized: "Refresh"))
            .accessibilityIdentifier("er-diagram-refresh")

            if let onBuildJoinQuery {
                Button(action: onBuildJoinQuery) {
                    Image(systemName: "arrow.triangle.merge")
                }
                .help(String(localized: "Build a join query from the selected tables"))
                .accessibilityLabel(String(localized: "Build Join Query"))
                .accessibilityIdentifier("er-diagram-build-join")
            }

            exportMenu

            if viewModel.hasStagedEdits {
                Divider().frame(height: 16)

                Button {
                    confirmDiscard()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .help(String(localized: "Discard Changes"))
                .accessibilityLabel(String(localized: "Discard Changes"))
                .accessibilityIdentifier("er-diagram-discard")
            }
        }
        .padding(12)
    }

    private func confirmDiscard() {
        let viewModel = viewModel
        Task { @MainActor in
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Discard Changes?"),
                message: String(localized: "The schema changes staged in this diagram will be lost."),
                confirmButton: String(localized: "Discard"),
                cancelButton: String(localized: "Cancel"),
                window: viewModel.coordinator?.contentWindow
            )
            if confirmed {
                viewModel.discardStagedEdits()
            }
        }
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

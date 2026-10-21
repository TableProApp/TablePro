import AppKit
import SwiftUI

struct ERDiagramView: View {
    @ObservedObject var viewModel: ERDiagramViewModel
    var onBuildJoinQuery: (([String]) -> Void)?
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var viewport: DiagramViewportController { viewModel.viewport }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            switch viewModel.loadState {
            case .loading:
                ProgressView(String(localized: "Loading schema…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    RevealedTextView(message)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Retry")) {
                        Task { await viewModel.loadDiagram() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded:
                if viewModel.graph.nodes.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tablecells")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("No tables found")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    diagramCanvas
                }
                ERDiagramToolbar(
                    viewModel: viewModel,
                    viewport: viewport,
                    onExport: export,
                    onCopyMermaid: copyMermaid,
                    onBuildJoinQuery: buildJoinQuery
                )
            }
        }
        .task { await viewModel.loadDiagram() }
    }

    // MARK: - Diagram Canvas

    // Built during `body`, so observation sees every model property the scene reads.
    private var diagramCanvas: some View {
        let scene = self.scene
        let actions = canvasActions
        return MagnifiableCanvasView(
            viewport: viewport,
            contentSize: viewModel.cachedCanvasSize,
            accessibilityIdentifier: "er-diagram-canvas",
            makeDocument: { ERDiagramSceneView() },
            updateDocument: { sceneView in
                sceneView.scene = scene
                sceneView.actions = actions
            }
        )
    }

    private var buildJoinQuery: (() -> Void)? {
        guard let onBuildJoinQuery else { return nil }
        let viewModel = viewModel
        return { onBuildJoinQuery(viewModel.selectedTableNames) }
    }

    private var canvasActions: ERDiagramCanvasActions {
        let viewModel = viewModel
        return ERDiagramCanvasActions(
            nodeAt: { viewModel.nodeId(at: $0) },
            select: { viewModel.selectedNodeId = $0 },
            beginDrag: { viewModel.beginDrag(at: $0) },
            updateDrag: { viewModel.updateDrag(translation: $0, currentPoint: $1) },
            endDrag: { viewModel.endDrag() },
            scrollBy: { viewModel.viewport.scrollBy($0) },
            copyImage: {
                guard let image = exportImage() else { return }
                ClipboardService.shared.writeImage(image)
            },
            toggleSelection: { viewModel.toggleSelection($0) },
            buildJoinQuery: buildJoinQuery
        )
    }

    private var scene: ERDiagramScene {
        ERDiagramScene(
            nodes: viewModel.graph.nodes,
            edges: viewModel.graph.edges,
            nodeRects: viewModel.cachedNodeRects,
            nodeIndex: viewModel.graph.nodeIndex,
            clusterColors: nodeClusterColors(nodes: viewModel.graph.nodes),
            selectedNodeIds: viewModel.selectedNodeIds,
            size: viewModel.cachedCanvasSize
        )
    }

    // MARK: - Cluster Colors

    private func nodeClusterColors(nodes: [ERTableNode]) -> [UUID: NSColor] {
        guard !differentiateWithoutColor else { return [:] }
        var colors: [UUID: NSColor] = [:]
        for node in nodes {
            if let color = ERClusterPalette.color(for: node.clusterId) {
                colors[node.id] = color
            }
        }
        return colors
    }

    // MARK: - Export

    private func exportImage() -> NSImage? {
        ERDiagramSceneRenderer.image(
            scene,
            appearance: viewport.effectiveAppearance,
            scale: DiagramExporter.renderScale
        )
    }

    private var exportTitle: String {
        viewModel.schemaName.map { "\(viewModel.databaseName).\($0)" } ?? viewModel.databaseName
    }

    private func exportData(_ format: ERDiagramExportFormat) -> Data? {
        switch format {
        case .png:
            return DiagramExporter.pngData(exportImage())
        case .svg:
            let svg = ERDiagramSceneRenderer.svgDocument(scene, appearance: viewport.effectiveAppearance, title: exportTitle)
            return Data(svg.utf8)
        case .pdf:
            return ERDiagramSceneRenderer.pdfData(scene, appearance: viewport.effectiveAppearance, title: exportTitle)
        case .mermaid:
            return Data(ERDiagramMermaidWriter.document(for: viewModel.graph).utf8)
        case .graphviz:
            return Data(ERDiagramDOTWriter.document(for: viewModel.graph).utf8)
        }
    }

    private func export(_ format: ERDiagramExportFormat) {
        DiagramExporter.save(
            exportData(format),
            contentType: format.contentType,
            formatName: format.name,
            defaultFileName: "er-diagram.\(format.fileExtension)",
            title: String(localized: "Export ER Diagram")
        )
    }

    private func copyMermaid() {
        ClipboardService.shared.writeText(ERDiagramMermaidWriter.markdownBlock(for: viewModel.graph))
    }
}

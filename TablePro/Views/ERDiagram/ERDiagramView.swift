import AppKit
import SwiftUI

struct ERDiagramView: View {
    @ObservedObject var viewModel: ERDiagramViewModel
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorScheme) private var colorScheme

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
                ERDiagramToolbar(viewModel: viewModel, viewport: viewport, onExport: exportDiagram)
            }
        }
        .task { await viewModel.loadDiagram() }
    }

    // MARK: - Diagram Canvas

    /// The scene is built here, during `body`, so observation sees every model property it reads;
    /// the document view only receives the finished value.
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
            }
        )
    }

    private var scene: ERDiagramScene {
        ERDiagramScene(
            nodes: viewModel.graph.nodes,
            edges: viewModel.graph.edges,
            nodeRects: viewModel.cachedNodeRects,
            nodeIndex: viewModel.graph.nodeIndex,
            clusterColors: nodeClusterColors(nodes: viewModel.graph.nodes),
            selectedNodeId: viewModel.selectedNodeId,
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

    // MARK: - Export Rendering

    private func exportImage() -> NSImage? {
        ERDiagramSceneRenderer.image(
            scene,
            appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance,
            scale: DiagramImageExporter.renderScale
        )
    }

    private func exportDiagram() {
        DiagramImageExporter.export(
            exportImage(),
            defaultFileName: "er-diagram.png",
            title: String(localized: "Export ER Diagram")
        )
    }
}

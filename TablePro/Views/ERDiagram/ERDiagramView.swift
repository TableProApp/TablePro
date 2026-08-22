import AppKit
import SwiftUI

struct ERDiagramView: View {
    @Bindable var viewModel: ERDiagramViewModel
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var viewport = DiagramViewportController()
    @State private var selectedNodeId: UUID?
    @State private var currentCursor: NSCursor?
    @State private var lastPanTranslation: CGSize = .zero

    /// The scroll view reports no visible rect until AppKit has laid it out, which happens after
    /// SwiftUI mounts it. The fit retries across a bounded number of main-actor hops rather than
    /// waiting on a wall-clock delay.
    private static let fitLayoutAttempts = 30

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
                    Text(message)
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
                    MagnifiableCanvasView(
                        viewport: viewport,
                        contentSize: viewModel.cachedCanvasSize,
                        accessibilityIdentifier: "er-diagram-canvas"
                    ) {
                        diagramContent
                    }
                }
                ERDiagramToolbar(viewModel: viewModel, viewport: viewport, onExport: exportDiagram)
            }
        }
        .onCopyCommand { DiagramImageExporter.copyItemProviders(of: makeExportView()) }
        .task {
            viewModel.viewport = viewport
            await viewModel.loadDiagram()
        }
        .task(id: viewModel.loadState) { await fitWhenLaidOut() }
    }

    // MARK: - Diagram Content

    private var diagramContent: some View {
        let nodeRects = viewModel.cachedNodeRects
        let edges = viewModel.graph.edges
        let nodes = viewModel.graph.nodes
        let nodeIndex = viewModel.graph.nodeIndex
        let selectedId = selectedNodeId
        let clusterColors = nodeClusterColors(nodes: nodes)
        let canvasSize = viewModel.cachedCanvasSize

        return Canvas { context, _ in
            ERDiagramEdgeRenderer.drawEdges(
                context: context,
                edges: edges,
                nodeRects: nodeRects,
                nodeIndex: nodeIndex
            )

            for node in nodes {
                guard let rect = nodeRects[node.id] else { continue }
                ERDiagramNodeRenderer.drawNode(
                    context: &context,
                    node: node,
                    rect: rect,
                    isSelected: selectedId == node.id,
                    clusterColor: clusterColors[node.id]
                )
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(Text("\(viewModel.graph.nodes.count) tables, \(viewModel.graph.edges.count) relationships"))
        .accessibilityAddTraits(.isImage)
        .onTapGesture { location in
            selectedNodeId = nodeAt(point: location)
        }
        .gesture(canvasGesture)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard !viewModel.isDragging else { return }
                let desired: NSCursor? = nodeAt(point: location) != nil ? .openHand : nil
                if desired !== currentCursor {
                    if currentCursor != nil { NSCursor.pop() }
                    if let cursor = desired { cursor.push() }
                    currentCursor = desired
                }
            case .ended:
                if currentCursor != nil {
                    NSCursor.pop()
                    currentCursor = nil
                }
            @unknown default:
                break
            }
        }
    }

    // MARK: - Initial Fit

    private func fitWhenLaidOut() async {
        guard viewModel.loadState == .loaded else { return }
        for _ in 0..<Self.fitLayoutAttempts {
            guard !Task.isCancelled, viewModel.needsInitialFit else { return }
            let visible = viewport.visibleDocumentRect
            if visible.width > 0, visible.height > 0 {
                viewport.fitToWindow()
                viewModel.needsInitialFit = false
                return
            }
            await Task.yield()
        }
    }

    // MARK: - Cluster Colors

    private func nodeClusterColors(nodes: [ERTableNode]) -> [UUID: Color] {
        guard !differentiateWithoutColor else { return [:] }
        var colors: [UUID: Color] = [:]
        for node in nodes {
            if let color = ERClusterPalette.color(for: node.clusterId) {
                colors[node.id] = color
            }
        }
        return colors
    }

    // MARK: - Hit Testing

    private func nodeAt(point: CGPoint) -> UUID? {
        viewModel.cachedNodeRects.first { $0.value.contains(point) }?.key
    }

    // MARK: - Canvas Gesture (pan + node drag)

    /// The local drag reports document coordinates, which is what hit testing and node dragging
    /// need. Panning reads the global drag instead, because scrolling the document moves the
    /// local space underneath the pointer and a local translation would cancel itself out.
    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .simultaneously(with: DragGesture(minimumDistance: 2, coordinateSpace: .global))
            .onChanged { value in
                guard let local = value.first else { return }
                if !viewModel.isDragging {
                    viewModel.beginDrag(at: local.startLocation)
                    if viewModel.draggingNodeId != nil {
                        if currentCursor != nil { NSCursor.pop() }
                        NSCursor.closedHand.push()
                        currentCursor = .closedHand
                    }
                }

                if viewModel.draggingNodeId != nil {
                    let currentPoint = CGPoint(
                        x: local.startLocation.x + local.translation.width,
                        y: local.startLocation.y + local.translation.height
                    )
                    viewModel.updateDrag(translation: local.translation, currentPoint: currentPoint)
                    return
                }

                guard let global = value.second else { return }
                panCanvas(to: global.translation)
            }
            .onEnded { _ in
                viewModel.endDrag()
                lastPanTranslation = .zero
                if currentCursor != nil {
                    NSCursor.pop()
                    currentCursor = nil
                }
            }
    }

    private func panCanvas(to translation: CGSize) {
        let delta = CGSize(
            width: translation.width - lastPanTranslation.width,
            height: translation.height - lastPanTranslation.height
        )
        lastPanTranslation = translation
        let magnification = max(viewport.magnification, 0.01)
        viewport.scrollBy(CGSize(width: -delta.width / magnification, height: -delta.height / magnification))
    }

    // MARK: - Export Rendering

    private func makeExportView() -> some View {
        let nodeRects = viewModel.cachedNodeRects
        let nodes = viewModel.graph.nodes
        let edges = viewModel.graph.edges
        let nodeIndex = viewModel.graph.nodeIndex
        let clusterColors = nodeClusterColors(nodes: nodes)

        let padding: CGFloat = 40
        let bounds = nodeRects.values.reduce(CGRect.null) { $0.union($1) }
        let exportWidth = bounds.isNull ? 100 : bounds.width + padding * 2
        let exportHeight = bounds.isNull ? 100 : bounds.height + padding * 2
        let offsetX = bounds.isNull ? 0 : -bounds.minX + padding
        let offsetY = bounds.isNull ? 0 : -bounds.minY + padding

        return Canvas { context, _ in
            context.translateBy(x: offsetX, y: offsetY)
            ERDiagramEdgeRenderer.drawEdges(
                context: context,
                edges: edges,
                nodeRects: nodeRects,
                nodeIndex: nodeIndex
            )
            for node in nodes {
                guard let rect = nodeRects[node.id] else { continue }
                ERDiagramNodeRenderer.drawNode(
                    context: &context,
                    node: node,
                    rect: rect,
                    isSelected: false,
                    clusterColor: clusterColors[node.id]
                )
            }
        }
        .frame(width: exportWidth, height: exportHeight)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func exportDiagram() {
        DiagramImageExporter.export(
            makeExportView(),
            defaultFileName: "er-diagram.png",
            title: String(localized: "Export ER Diagram")
        )
    }
}

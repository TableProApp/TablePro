import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

struct ERDiagramView: View {
    @Bindable var viewModel: ERDiagramViewModel
    @State private var selectedNodeId: UUID?
    @State private var scrollMonitor: Any?
    @State private var currentCursor: NSCursor?
    @State private var magnifyStartMag: CGFloat?

    private static let logger = Logger(subsystem: "com.TablePro", category: "ERDiagramView")

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            switch viewModel.loadState {
            case .loading:
                ProgressView(String(localized: "Loading schema..."))
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
                    diagramContent
                }
                ERDiagramToolbar(viewModel: viewModel, onExport: exportDiagram)
                .onKeyPress(characters: .init(charactersIn: "c"), phases: .down) { keyPress in
                    guard keyPress.modifiers.contains(.command) else { return .ignored }
                    copyDiagramToClipboard()
                    return .handled
                }
            }
        }
        .task { await viewModel.loadDiagram() }
    }

    // MARK: - Diagram Content

    private var diagramContent: some View {
        GeometryReader { proxy in
            let nodeRects = viewModel.cachedNodeRects
            let edges = viewModel.graph.edges
            let nodes = viewModel.graph.nodes
            let nodeIndex = viewModel.graph.nodeIndex
            let selectedId = selectedNodeId
            let mag = viewModel.magnification
            let offset = viewModel.canvasOffset

            Canvas { context, _ in
                context.translateBy(x: offset.x, y: offset.y)
                context.scaleBy(x: mag, y: mag)

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
                        isSelected: selectedId == node.id
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                viewModel.viewportSize = proxy.size
                if viewModel.needsInitialFit && proxy.size.width > 0 {
                    viewModel.fitToWindow()
                    viewModel.needsInitialFit = false
                }
            }
            .onChange(of: proxy.size) { _, newSize in
                viewModel.viewportSize = newSize
                if viewModel.needsInitialFit && newSize.width > 0 {
                    viewModel.fitToWindow()
                    viewModel.needsInitialFit = false
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(Text("\(viewModel.graph.nodes.count) tables, \(viewModel.graph.edges.count) relationships"))
        .accessibilityAddTraits(.isImage)
        .onTapGesture { location in
            selectedNodeId = nodeAt(point: location)
        }
        .gesture(combinedGesture.simultaneously(with: magnifyGesture))
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                viewModel.isMouseOverCanvas = true
                guard !viewModel.isDragging else { return }
                let desired: NSCursor? = nodeAt(point: location) != nil ? .openHand : nil
                if desired !== currentCursor {
                    if currentCursor != nil { NSCursor.pop() }
                    if let cursor = desired { cursor.push() }
                    currentCursor = desired
                }
            case .ended:
                viewModel.isMouseOverCanvas = false
                if currentCursor != nil {
                    NSCursor.pop()
                    currentCursor = nil
                }
            @unknown default:
                break
            }
        }
        .onAppear {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard viewModel.isMouseOverCanvas else { return event }
                if event.modifierFlags.contains(.command) {
                    let zoomDelta = event.scrollingDeltaY * 0.01
                    viewModel.zoom(to: viewModel.magnification + zoomDelta)
                    return nil
                }
                let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
                viewModel.canvasOffset = CGPoint(
                    x: viewModel.canvasOffset.x + event.scrollingDeltaX * multiplier,
                    y: viewModel.canvasOffset.y + event.scrollingDeltaY * multiplier
                )
                return nil
            }
        }
        .onDisappear {
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }
    }

    // MARK: - Hit Testing

    private func nodeAt(point: CGPoint) -> UUID? {
        let canvasPoint = CGPoint(
            x: (point.x - viewModel.canvasOffset.x) / viewModel.magnification,
            y: (point.y - viewModel.canvasOffset.y) / viewModel.magnification
        )
        for (id, rect) in viewModel.cachedNodeRects where rect.contains(canvasPoint) {
            return id
        }
        return nil
    }

    // MARK: - Combined Gesture (pan + node drag)

    private var combinedGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !viewModel.isDragging {
                    viewModel.beginDrag(at: value.startLocation)
                    if viewModel.draggingNodeId != nil {
                        if currentCursor != nil { NSCursor.pop() }
                        NSCursor.closedHand.push()
                        currentCursor = .closedHand
                    }
                }
                let currentPoint = CGPoint(
                    x: value.startLocation.x + value.translation.width,
                    y: value.startLocation.y + value.translation.height
                )
                viewModel.updateDrag(translation: value.translation, currentPoint: currentPoint)
            }
            .onEnded { _ in
                viewModel.endDrag()
                if currentCursor != nil {
                    NSCursor.pop()
                    currentCursor = nil
                }
            }
    }

    // MARK: - Pinch-to-Zoom

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyStartMag == nil {
                    magnifyStartMag = viewModel.magnification
                }
                let base = magnifyStartMag ?? viewModel.magnification
                let newMag = max(0.25, min(3.0, base * value.magnification))
                viewModel.zoom(to: newMag, anchor: value.startLocation)
            }
            .onEnded { _ in
                magnifyStartMag = nil
            }
    }

    // MARK: - Export Rendering

    private func makeExportView() -> some View {
        let nodeRects = viewModel.cachedNodeRects
        let nodes = viewModel.graph.nodes
        let edges = viewModel.graph.edges
        let nodeIndex = viewModel.graph.nodeIndex

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
                ERDiagramNodeRenderer.drawNode(context: &context, node: node, rect: rect, isSelected: false)
            }
        }
        .frame(width: exportWidth, height: exportHeight)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func copyDiagramToClipboard() {
        let renderer = ImageRenderer(content: makeExportView())
        renderer.scale = 2.0
        guard let image = renderer.nsImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func exportDiagram() {
        let renderer = ImageRenderer(content: makeExportView())
        renderer.scale = 2.0

        guard let image = renderer.nsImage else {
            Self.logger.error("Failed to render ER diagram to image")
            let alert = NSAlert()
            alert.messageText = String(localized: "Export Failed")
            alert.informativeText = String(localized: "Failed to render the diagram image.")
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "er-diagram.png"
        panel.title = String(localized: "Export ER Diagram")
        panel.message = String(localized: "Choose a location to save the diagram as PNG.")

        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:])
            else { return }
            do {
                try pngData.write(to: url)
            } catch {
                Self.logger.error("Failed to write PNG: \(error.localizedDescription)")
            }
        }
    }
}

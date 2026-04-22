import AppKit
import Foundation
import os
import SwiftUI

@MainActor
@Observable
final class ERDiagramViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ERDiagram")

    // MARK: - Configuration

    let connectionId: UUID
    let schemaKey: String

    // MARK: - State

    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)

        static func == (lhs: LoadState, rhs: LoadState) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading), (.loaded, .loaded): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    var loadState: LoadState = .loading
    var needsInitialFit = true
    var graph: ERDiagramGraph = .empty
    var magnification: CGFloat = 1.0
    var isCompactMode = false {
        didSet { rebuildDisplayColumns() }
    }

    // MARK: - Canvas Viewport

    var canvasOffset: CGPoint = .zero
    var viewportSize: CGSize = .zero
    var isMouseOverCanvas = false

    // MARK: - Drag State

    private(set) var isDragging = false
    private(set) var draggingNodeId: UUID?
    @ObservationIgnored private var dragNodeStart: CGPoint?
    @ObservationIgnored private var panStart: CGPoint?
    @ObservationIgnored private var lastDragTranslation: CGSize = .zero

    // MARK: - Auto-Pan

    @ObservationIgnored nonisolated(unsafe) private var autoPanTask: Task<Void, Never>?
    @ObservationIgnored private var autoPanVelocity: CGPoint = .zero
    @ObservationIgnored private var autoPanAccum: CGPoint = .zero

    private static let edgeThreshold: CGFloat = 40
    private static let maxPanSpeed: CGFloat = 8

    // MARK: - Positions

    private(set) var computedLayout: [UUID: CGPoint] = [:]
    private(set) var positionOverrides: [UUID: CGPoint] = [:]
    @ObservationIgnored nonisolated(unsafe) private var layoutTask: Task<Void, Never>?
    private(set) var cachedNodeRects: [UUID: CGRect] = [:]
    @ObservationIgnored private var columnCountByNodeId: [UUID: Int] = [:]
    @ObservationIgnored private var nodeIdToName: [UUID: String] = [:]

    // MARK: - Initialization

    init(connectionId: UUID, schemaKey: String) {
        self.connectionId = connectionId
        self.schemaKey = schemaKey
    }

    deinit {
        autoPanTask?.cancel()
        layoutTask?.cancel()
    }

    // MARK: - Loading

    func loadDiagram() async {
        guard loadState != .loaded else { return }
        loadState = .loading

        // Wait for connection to be established (handles app restore race condition)
        var driver: DatabaseDriver?
        for _ in 0..<20 {
            driver = DatabaseManager.shared.driver(for: connectionId)
            if driver != nil { break }
            try? await Task.sleep(for: .milliseconds(500))
        }

        guard let driver else {
            loadState = .failed(String(localized: "No database connection"))
            return
        }

        do {
            async let columnsResult = driver.fetchAllColumns()
            async let fksResult = driver.fetchAllForeignKeys()
            let (allColumns, allFKs) = try await (columnsResult, fksResult)

            let builtGraph = ERDiagramGraphBuilder.build(
                allColumns: allColumns,
                allForeignKeys: allFKs
            )
            graph = builtGraph
            nodeIdToName = Dictionary(uniqueKeysWithValues: builtGraph.nodes.map { ($0.id, $0.tableName) })

            let layout = await Task.detached {
                ERDiagramLayout.compute(graph: builtGraph)
            }.value
            computedLayout = layout
            loadPersistedPositions()
            invalidateCachedRects()
            loadState = .loaded
            needsInitialFit = true

            Self.logger.debug("ER diagram loaded: \(self.graph.nodes.count) tables, \(self.graph.edges.count) edges")
        } catch {
            Self.logger.error("Failed to load ER diagram: \(error.localizedDescription)")
            loadState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Position Management

    func position(for nodeId: UUID) -> CGPoint {
        positionOverrides[nodeId] ?? computedLayout[nodeId] ?? .zero
    }

    func setPositionOverride(nodeId: UUID, position: CGPoint) {
        positionOverrides[nodeId] = position
        let height = ERDiagramLayout.estimateHeight(columnCount: columnCountByNodeId[nodeId] ?? 1)
        cachedNodeRects[nodeId] = CGRect(
            x: position.x - ERDiagramLayout.nodeWidth / 2,
            y: position.y - height / 2,
            width: ERDiagramLayout.nodeWidth,
            height: height
        )
    }

    func persistPositions() {
        let namedPositions = positionOverrides.reduce(into: [String: CGPoint]()) { result, pair in
            if let name = nodeIdToName[pair.key] {
                result[name] = pair.value
            }
        }
        ERDiagramPositionStorage.shared.save(namedPositions, connectionId: connectionId, schemaKey: schemaKey)
    }

    func resetLayout() {
        positionOverrides.removeAll()
        ERDiagramPositionStorage.shared.clear(connectionId: connectionId, schemaKey: schemaKey)
        invalidateCachedRects()
        let currentGraph = graph
        layoutTask?.cancel()
        layoutTask = Task {
            let layout = await Task.detached {
                ERDiagramLayout.compute(graph: currentGraph)
            }.value
            guard !Task.isCancelled else { return }
            computedLayout = layout
            invalidateCachedRects()
        }
    }

    // MARK: - Compact Mode

    private func rebuildDisplayColumns() {
        graph.nodes = graph.nodes.map { node in
            var updated = node
            updated.displayColumns = isCompactMode
                ? node.columns.filter { $0.isPrimaryKey || $0.isForeignKey }
                : node.columns
            if updated.displayColumns.isEmpty {
                updated.displayColumns = node.columns
            }
            return updated
        }
        invalidateCachedRects()
        let currentGraph = graph
        layoutTask?.cancel()
        layoutTask = Task {
            let layout = await Task.detached {
                ERDiagramLayout.compute(graph: currentGraph)
            }.value
            guard !Task.isCancelled else { return }
            computedLayout = layout
            invalidateCachedRects()
        }
    }

    // MARK: - Canvas Size

    private(set) var cachedCanvasSize = CGSize(width: 800, height: 600)

    // MARK: - Node Rect (for edge rendering)

    func nodeRect(for nodeId: UUID) -> CGRect {
        if let cached = cachedNodeRects[nodeId] { return cached }
        let center = position(for: nodeId)
        let height = ERDiagramLayout.estimateHeight(columnCount: columnCountByNodeId[nodeId] ?? 1)
        return CGRect(
            x: center.x - ERDiagramLayout.nodeWidth / 2,
            y: center.y - height / 2,
            width: ERDiagramLayout.nodeWidth,
            height: height
        )
    }

    // MARK: - Cache Invalidation

    func invalidateCachedRects() {
        columnCountByNodeId = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.displayColumns.count) })
        var rects: [UUID: CGRect] = [:]
        for node in graph.nodes {
            let center = position(for: node.id)
            let height = ERDiagramLayout.estimateHeight(columnCount: columnCountByNodeId[node.id] ?? 1)
            rects[node.id] = CGRect(
                x: center.x - ERDiagramLayout.nodeWidth / 2,
                y: center.y - height / 2,
                width: ERDiagramLayout.nodeWidth,
                height: height
            )
        }
        cachedNodeRects = rects

        if graph.nodes.isEmpty {
            cachedCanvasSize = CGSize(width: 800, height: 600)
        } else {
            var csMaxX: CGFloat = 0
            var csMaxY: CGFloat = 0
            for (_, rect) in rects {
                csMaxX = max(csMaxX, rect.maxX)
                csMaxY = max(csMaxY, rect.maxY)
            }
            cachedCanvasSize = CGSize(width: csMaxX + 80, height: csMaxY + 80)
        }
    }

    // MARK: - Drag & Auto-Pan

    func beginDrag(at startLocation: CGPoint) {
        isDragging = true
        let canvasPoint = CGPoint(
            x: (startLocation.x - canvasOffset.x) / magnification,
            y: (startLocation.y - canvasOffset.y) / magnification
        )
        var hitNodeId: UUID?
        for (id, rect) in cachedNodeRects where rect.contains(canvasPoint) {
            hitNodeId = id
            break
        }
        draggingNodeId = hitNodeId
        if let nodeId = hitNodeId {
            dragNodeStart = position(for: nodeId)
        } else {
            panStart = canvasOffset
        }
    }

    func updateDrag(translation: CGSize, currentPoint: CGPoint) {
        lastDragTranslation = translation

        if let nodeId = draggingNodeId, let nodeStart = dragNodeStart {
            let totalDelta = CGSize(
                width: (translation.width + autoPanAccum.x) / magnification,
                height: (translation.height + autoPanAccum.y) / magnification
            )
            setPositionOverride(
                nodeId: nodeId,
                position: CGPoint(x: nodeStart.x + totalDelta.width, y: nodeStart.y + totalDelta.height)
            )
            updateAutoPanVelocity(for: currentPoint)
        } else if let start = panStart {
            canvasOffset = CGPoint(
                x: start.x + translation.width,
                y: start.y + translation.height
            )
        }
    }

    func endDrag() {
        if draggingNodeId != nil {
            persistPositions()
        }
        isDragging = false
        draggingNodeId = nil
        dragNodeStart = nil
        panStart = nil
        lastDragTranslation = .zero
        stopAutoPan()
    }

    private func updateAutoPanVelocity(for point: CGPoint) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopAutoPan()
            return
        }
        let t = Self.edgeThreshold
        let s = Self.maxPanSpeed
        var v = CGPoint.zero

        if point.x > viewportSize.width - t {
            v.x = -s * min(1, max(0, 1 - (viewportSize.width - point.x) / t))
        } else if point.x < t {
            v.x = s * min(1, max(0, 1 - point.x / t))
        }
        if point.y > viewportSize.height - t {
            v.y = -s * min(1, max(0, 1 - (viewportSize.height - point.y) / t))
        } else if point.y < t {
            v.y = s * min(1, max(0, 1 - point.y / t))
        }

        autoPanVelocity = v
        if v != .zero && autoPanTask == nil {
            autoPanTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.autoPanTick()
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        } else if v == .zero && autoPanTask != nil {
            autoPanTask?.cancel()
            autoPanTask = nil
        }
    }

    private func autoPanTick() {
        guard autoPanVelocity != .zero, draggingNodeId != nil else {
            stopAutoPan()
            return
        }

        canvasOffset.x += autoPanVelocity.x
        canvasOffset.y += autoPanVelocity.y
        autoPanAccum.x -= autoPanVelocity.x
        autoPanAccum.y -= autoPanVelocity.y

        if let nodeId = draggingNodeId, let nodeStart = dragNodeStart {
            let totalDelta = CGSize(
                width: (lastDragTranslation.width + autoPanAccum.x) / magnification,
                height: (lastDragTranslation.height + autoPanAccum.y) / magnification
            )
            setPositionOverride(
                nodeId: nodeId,
                position: CGPoint(x: nodeStart.x + totalDelta.width, y: nodeStart.y + totalDelta.height)
            )
        }
    }

    private func stopAutoPan() {
        autoPanTask?.cancel()
        autoPanTask = nil
        autoPanVelocity = .zero
        autoPanAccum = .zero
    }

    // MARK: - Zoom

    func zoom(to newMag: CGFloat, anchor: CGPoint? = nil) {
        let clamped = max(0.25, min(3.0, newMag))
        let center = anchor ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let canvasPoint = CGPoint(
            x: (center.x - canvasOffset.x) / magnification,
            y: (center.y - canvasOffset.y) / magnification
        )
        withAnimation(.easeOut(duration: 0.2)) {
            canvasOffset = CGPoint(
                x: center.x - canvasPoint.x * clamped,
                y: center.y - canvasPoint.y * clamped
            )
            magnification = clamped
        }
    }

    func fitToWindow() {
        guard !graph.nodes.isEmpty, viewportSize.width > 0, viewportSize.height > 0 else { return }
        let diagramSize = cachedCanvasSize
        let padding: CGFloat = 40
        let scaleX = (viewportSize.width - padding * 2) / diagramSize.width
        let scaleY = (viewportSize.height - padding * 2) / diagramSize.height
        let fitScale = max(0.25, min(1.0, min(scaleX, scaleY)))

        withAnimation(.easeOut(duration: 0.3)) {
            magnification = fitScale
            canvasOffset = CGPoint(
                x: (viewportSize.width - diagramSize.width * fitScale) / 2,
                y: (viewportSize.height - diagramSize.height * fitScale) / 2
            )
        }
    }

    // MARK: - Private

    private func loadPersistedPositions() {
        let stored = ERDiagramPositionStorage.shared.load(connectionId: connectionId, schemaKey: schemaKey)
        for (tableName, point) in stored {
            if let nodeId = graph.nodeIndex[tableName] {
                positionOverrides[nodeId] = point
            }
        }
    }
}

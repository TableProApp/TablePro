import AppKit
import Combine
import Foundation
import os
import SwiftUI
import TableProPluginKit

@MainActor
@Observable
final class ERDiagramViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ERDiagram")

    // MARK: - Configuration

    let connectionId: UUID
    let databaseName: String
    let schemaKey: String
    let schemaName: String?

    /// The diagram is bound to the database and the schema its tab was opened on, so moving
    /// the sidebar to another database or schema cannot repoint an open diagram.
    private var scope: DatabaseScope? {
        services.databaseManager.resolvedScope(database: databaseName, schema: schemaName, for: connectionId)
    }

    private static let noSchemaMarker = "default"

    /// `schemaKey` is the diagram's identity, written as `database.schema` with
    /// `noSchemaMarker` standing in for an engine that has no schemas. It is also the only
    /// record of the schema a diagram tab was opened on, because `addERDiagramTab` writes a
    /// database into the tab's table context but never a schema. Stripping the database
    /// prefix rather than splitting on the separator keeps a database name that contains a
    /// dot intact.
    static func resolveSchemaName(fromSchemaKey schemaKey: String, databaseName: String) -> String? {
        let prefix = databaseName + "."
        guard !databaseName.isEmpty, schemaKey.hasPrefix(prefix) else { return nil }
        let schema = String(schemaKey.dropFirst(prefix.count))
        guard !schema.isEmpty, schema != noSchemaMarker else { return nil }
        return schema
    }

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
    var isCompactMode = false {
        didSet { rebuildVisibleGraph() }
    }

    var collapseJunctions = true {
        didSet { rebuildVisibleGraph() }
    }

    var hasJunctionTables: Bool { !fullGraph.junctionTableIds.isEmpty }

    @ObservationIgnored private var fullGraph: ERDiagramGraph = .empty
    @ObservationIgnored private var allColumns: [String: [ColumnInfo]] = [:]
    @ObservationIgnored private var allForeignKeys: [String: [ForeignKeyInfo]] = [:]

    // MARK: - Canvas Viewport

    /// AppKit owns pan and zoom, so every coordinate the view hands over is already in document
    /// space. The viewport is only needed to nudge the scroll position while auto-panning.
    @ObservationIgnored weak var viewport: DiagramViewportController?

    // MARK: - Drag State

    private(set) var isDragging = false
    private(set) var draggingNodeId: UUID?
    @ObservationIgnored private var dragNodeStart: CGPoint?
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

    @ObservationIgnored private let services: AppServices

    // MARK: - Initialization

    init(connectionId: UUID, databaseName: String, schemaKey: String, services: AppServices = .live) {
        self.connectionId = connectionId
        self.databaseName = databaseName
        self.schemaKey = schemaKey
        self.schemaName = Self.resolveSchemaName(fromSchemaKey: schemaKey, databaseName: databaseName)
        self.services = services
    }

    deinit {
        autoPanTask?.cancel()
        layoutTask?.cancel()
    }

    // MARK: - Loading

    func loadDiagram() async {
        guard loadState != .loaded else { return }
        loadState = .loading

        if services.databaseManager.driver(for: connectionId) == nil {
            await waitForConnection()
        }

        guard services.databaseManager.driver(for: connectionId) != nil else {
            loadState = .failed(String(localized: "No database connection"))
            return
        }

        guard let scope else {
            loadState = .failed(String(localized: "This diagram is not bound to a database"))
            return
        }

        do {
            let (columns, foreignKeys, indexes) = try await services.databaseManager.withMetadataDriver(
                scope: scope, workload: .bulk
            ) { driver in
                let cols = try await driver.fetchAllColumns()
                let fks = try await driver.fetchAllForeignKeys()
                let idx = try await driver.fetchIndexes(forTables: Array(fks.keys))
                return (cols, fks, idx)
            }

            allColumns = columns
            allForeignKeys = foreignKeys
            fullGraph = ERDiagramGraphBuilder.build(
                allColumns: columns,
                allForeignKeys: foreignKeys,
                allIndexes: indexes
            )

            nodeIdToName = Dictionary(uniqueKeysWithValues: fullGraph.nodes.map { ($0.id, $0.tableName) })
            let visibleGraph = makeVisibleGraph()
            graph = visibleGraph

            let layout = await Task.detached {
                ERDiagramLayout.compute(graph: visibleGraph)
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

    private func waitForConnection() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let cancellableBox = OSAllocatedUnfairLock<AnyCancellable?>(initialState: nil)
            let timeoutTaskBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

            @Sendable func resumeOnce() {
                let alreadyResumed = resumed.withLock { value -> Bool in
                    if value { return true }
                    value = true
                    return false
                }
                guard !alreadyResumed else { return }
                timeoutTaskBox.withLock { $0?.cancel(); $0 = nil }
                cancellableBox.withLock { $0 = nil }
                continuation.resume()
            }

            let targetId = self.connectionId
            let cancellable = services.appEvents.databaseDidConnect
                .receive(on: RunLoop.main)
                .sink { payload in
                    guard payload.connectionId == targetId else { return }
                    resumeOnce()
                }
            cancellableBox.withLock { $0 = cancellable }

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(10))
                resumeOnce()
            }
            timeoutTaskBox.withLock { $0 = timeoutTask }
        }
    }

    // MARK: - Position Management

    func position(for nodeId: UUID) -> CGPoint {
        positionOverrides[nodeId] ?? computedLayout[nodeId] ?? .zero
    }

    func setPositionOverride(nodeId: UUID, position: CGPoint) {
        positionOverrides[nodeId] = position
        let height = ERDiagramLayout.estimateHeight(columnCount: columnCountByNodeId[nodeId] ?? 1)
        let rect = CGRect(
            x: position.x - ERDiagramLayout.nodeWidth / 2,
            y: position.y - height / 2,
            width: ERDiagramLayout.nodeWidth,
            height: height
        )
        cachedNodeRects[nodeId] = rect

        // The scroll view's document is sized from this, so a node dragged past the load-time
        // bounds has to grow it or the node ends up somewhere the canvas cannot scroll to.
        cachedCanvasSize = CGSize(
            width: max(cachedCanvasSize.width, rect.maxX + Self.canvasPadding),
            height: max(cachedCanvasSize.height, rect.maxY + Self.canvasPadding)
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

    // MARK: - Visible Graph (compact mode + junction collapse)

    private func makeVisibleGraph() -> ERDiagramGraph {
        var projected = fullGraph.projected(collapseJunctions: collapseJunctions)
        projected.nodes = projected.nodes.map { node in
            var updated = node
            updated.displayColumns = isCompactMode
                ? node.columns.filter { $0.isPrimaryKey || $0.isForeignKey }
                : node.columns
            if updated.displayColumns.isEmpty {
                updated.displayColumns = node.columns
            }
            return updated
        }
        return projected
    }

    private func rebuildVisibleGraph() {
        guard loadState == .loaded else { return }
        let visibleGraph = makeVisibleGraph()
        graph = visibleGraph
        invalidateCachedRects()
        layoutTask?.cancel()
        layoutTask = Task {
            let layout = await Task.detached {
                ERDiagramLayout.compute(graph: visibleGraph)
            }.value
            guard !Task.isCancelled else { return }
            computedLayout = layout
            invalidateCachedRects()
        }
    }

    // MARK: - SQL Export

    func exportSchemaAsSQL() {
        guard loadState == .loaded, !fullGraph.nodes.isEmpty else { return }
        guard let driver = services.databaseManager.driver(for: connectionId) else { return }
        let databaseType = driver.connection.type
        do {
            let dialect = try resolveSQLDialect(for: databaseType)
            let quote = quoteIdentifierFromDialect(dialect)
            let sql = ERDiagramSQLExporter.generate(
                tableNames: fullGraph.nodes.map(\.tableName),
                allColumns: allColumns,
                allForeignKeys: allForeignKeys,
                isSQLite: databaseType == .sqlite,
                quoteIdentifier: quote
            )
            guard !sql.isEmpty else { return }

            let payload = EditorTabPayload(
                connectionId: connectionId,
                tabType: .query,
                databaseName: scope?.database ?? services.databaseManager.browseDatabaseName(for: driver.connection),
                initialQuery: sql,
                skipAutoExecute: true,
                tabTitle: String(localized: "Schema SQL")
            )
            WindowManager.shared.openTab(payload: payload)
        } catch {
            Self.logger.error("Failed to export ER diagram as SQL: \(error.localizedDescription)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Export Failed"),
                message: error.localizedDescription,
                window: nil
            )
        }
    }

    // MARK: - Canvas Size

    private(set) var cachedCanvasSize = CGSize(width: 800, height: 600)
    private static let canvasPadding: CGFloat = 80

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
            cachedCanvasSize = CGSize(
                width: csMaxX + Self.canvasPadding, height: csMaxY + Self.canvasPadding
            )
        }
    }

    // MARK: - Drag & Auto-Pan

    func beginDrag(at startLocation: CGPoint) {
        isDragging = true
        draggingNodeId = cachedNodeRects.first { $0.value.contains(startLocation) }?.key
        dragNodeStart = draggingNodeId.map { position(for: $0) }
    }

    /// The translation arrives in document units and already carries any scrolling that happened
    /// since the drag began, so the accumulator only has to cover the ticks between two events.
    func updateDrag(translation: CGSize, currentPoint: CGPoint) {
        lastDragTranslation = translation
        guard let nodeId = draggingNodeId, let nodeStart = dragNodeStart else { return }

        autoPanAccum = .zero
        setPositionOverride(
            nodeId: nodeId,
            position: CGPoint(x: nodeStart.x + translation.width, y: nodeStart.y + translation.height)
        )
        updateAutoPanVelocity(for: currentPoint)
    }

    func endDrag() {
        if draggingNodeId != nil {
            persistPositions()
        }
        isDragging = false
        draggingNodeId = nil
        dragNodeStart = nil
        lastDragTranslation = .zero
        stopAutoPan()
    }

    /// The edge band and the pan speed are tuned in screen points, so both are divided by the
    /// magnification to reach the document units the viewport scrolls in.
    private func updateAutoPanVelocity(for point: CGPoint) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let viewport else {
            stopAutoPan()
            return
        }

        let visible = viewport.visibleDocumentRect
        guard visible.width > 0, visible.height > 0 else {
            stopAutoPan()
            return
        }

        let magnification = max(viewport.magnification, 0.01)
        let threshold = Self.edgeThreshold / magnification
        let speed = Self.maxPanSpeed / magnification
        var velocity = CGPoint.zero

        if point.x > visible.maxX - threshold {
            velocity.x = -speed * min(1, max(0, 1 - (visible.maxX - point.x) / threshold))
        } else if point.x < visible.minX + threshold {
            velocity.x = speed * min(1, max(0, 1 - (point.x - visible.minX) / threshold))
        }
        if point.y > visible.maxY - threshold {
            velocity.y = -speed * min(1, max(0, 1 - (visible.maxY - point.y) / threshold))
        } else if point.y < visible.minY + threshold {
            velocity.y = speed * min(1, max(0, 1 - (point.y - visible.minY) / threshold))
        }

        autoPanVelocity = velocity
        if velocity != .zero && autoPanTask == nil {
            autoPanTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.autoPanTick()
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        } else if velocity == .zero && autoPanTask != nil {
            autoPanTask?.cancel()
            autoPanTask = nil
        }
    }

    private func autoPanTick() {
        guard autoPanVelocity != .zero, let nodeId = draggingNodeId, let nodeStart = dragNodeStart else {
            stopAutoPan()
            return
        }

        let delta = CGSize(width: -autoPanVelocity.x, height: -autoPanVelocity.y)
        viewport?.scrollBy(delta)
        autoPanAccum.x += delta.width
        autoPanAccum.y += delta.height

        setPositionOverride(
            nodeId: nodeId,
            position: CGPoint(
                x: nodeStart.x + lastDragTranslation.width + autoPanAccum.x,
                y: nodeStart.y + lastDragTranslation.height + autoPanAccum.y
            )
        )
    }

    private func stopAutoPan() {
        autoPanTask?.cancel()
        autoPanTask = nil
        autoPanVelocity = .zero
        autoPanAccum = .zero
    }

    // MARK: - Private

    private func loadPersistedPositions() {
        let stored = ERDiagramPositionStorage.shared.load(connectionId: connectionId, schemaKey: schemaKey)
        for (tableName, point) in stored {
            if let nodeId = fullGraph.nodeIndex[tableName] {
                positionOverrides[nodeId] = point
            }
        }
    }
}

import AppKit
import Combine
import Foundation
import os
import SwiftUI
import TableProPluginKit

@MainActor
final class ERDiagramViewModel: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ERDiagram")

    // MARK: - Configuration

    let connectionId: UUID
    let databaseName: String
    let schemaKey: String
    let schemaName: String?

    /// The diagram is bound to the database and the schema its tab was opened on, so moving
    /// the sidebar to another database or schema cannot repoint an open diagram.
    var scope: DatabaseScope? {
        services.databaseManager.resolvedScope(database: databaseName, schema: schemaName, for: connectionId)
    }

    nonisolated private static let noSchemaMarker = "default"

    /// `schemaKey` is the diagram's identity, written as `database.schema` with
    /// `noSchemaMarker` standing in for an engine that has no schemas. It is also the only
    /// record of the schema a diagram tab was opened on, because `addERDiagramTab` writes a
    /// database into the tab's table context but never a schema. Stripping the database
    /// prefix rather than splitting on the separator keeps a database name that contains a
    /// dot intact.
    nonisolated static func resolveSchemaName(fromSchemaKey schemaKey: String, databaseName: String) -> String? {
        let prefix = databaseName + "."
        guard !databaseName.isEmpty, schemaKey.hasPrefix(prefix) else { return nil }
        let schema = String(schemaKey.dropFirst(prefix.count))
        guard !schema.isEmpty, schema != noSchemaMarker else { return nil }
        return schema
    }

    nonisolated static func schemaKey(databaseName: String, schema: String?) -> String {
        "\(databaseName).\(schema ?? noSchemaMarker)"
    }

    nonisolated static func schemaKeyPreserves(_ schema: String, databaseName: String) -> Bool {
        resolveSchemaName(fromSchemaKey: schemaKey(databaseName: databaseName, schema: schema), databaseName: databaseName)
            == schema
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

    @Published var loadState: LoadState = .loading
    @Published var graph: ERDiagramGraph = .empty
    @Published var isCompactMode = false {
        didSet { rebuildVisibleGraph() }
    }

    @Published var collapseJunctions = true {
        didSet { rebuildVisibleGraph() }
    }

    var hasJunctionTables: Bool { !fullGraph.junctionTableIds.isEmpty }

    private var fullGraph: ERDiagramGraph = .empty
    // The bulk column read takes in views too, and a view is edited on the terms its own kind allows.
    private(set) var objectKinds: [String: TableInfo.TableType] = [:]

    // MARK: - Canvas Viewport

    /// AppKit owns pan and zoom, so every coordinate the view hands over is already in document
    /// space. The viewport is only needed to nudge the scroll position while auto-panning.
    ///
    /// It belongs to the model rather than the view because an editor-tab switch destroys
    /// `ERDiagramView` and rebuilds it against the same model: a viewport held as view state came
    /// back at 100% scrolled to the origin every time the user left the tab and returned.
    let viewport = DiagramViewportController()

    /// Selection outlives the view for the same reason.
    @Published var selectedNodeId: UUID?
    @Published var selectedEdgeId: UUID?

    // MARK: - Editing

    weak var coordinator: MainContentCoordinator?
    var tabId: UUID?
    @Published var editSheet: ERDiagramEditSheet?
    @Published private(set) var hasStagedEdits = false
    // An edit confirmed in a sheet is staged only once its table's baseline has loaded.
    @Published private(set) var stagingCount = 0
    private var stagingTasks: [UUID: Task<Void, Never>] = [:]
    @Published private(set) var isRefreshing = false
    private var refreshRequested = false
    private var editsStorage: ERDiagramSchemaEdits?
    private let connection: DatabaseConnection?
    var pendingPlacement: ERDiagramPendingPlacement?
    private var objectChangeCancellable: AnyCancellable?

    // MARK: - Drag State

    @Published private(set) var isDragging = false
    @Published private(set) var draggingNodeId: UUID?
    private var dragNodeStart: CGPoint?
    private var lastDragTranslation: CGSize = .zero

    // MARK: - Auto-Pan

    nonisolated(unsafe) private var autoPanTask: Task<Void, Never>?
    private var autoPanVelocity: CGPoint = .zero
    private var autoPanAccum: CGPoint = .zero

    private static let edgeThreshold: CGFloat = 40
    private static let maxPanSpeed: CGFloat = 8

    // MARK: - Positions

    @Published private(set) var computedLayout: [UUID: CGPoint] = [:]
    @Published private(set) var positionOverrides: [UUID: CGPoint] = [:]
    nonisolated(unsafe) private var layoutTask: Task<Void, Never>?
    @Published private(set) var cachedNodeRects: [UUID: CGRect] = [:]
    private var columnCountByNodeId: [UUID: Int] = [:]
    private var nodeIdToName: [UUID: String] = [:]

    let services: AppServices
    private let autoPanClock: any Clock<Duration>
    private var loadTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        connectionId: UUID,
        databaseName: String,
        schemaKey: String,
        connection: DatabaseConnection? = nil,
        services: AppServices = .live,
        autoPanClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.connectionId = connectionId
        self.databaseName = databaseName
        self.schemaKey = schemaKey
        self.schemaName = Self.resolveSchemaName(fromSchemaKey: schemaKey, databaseName: databaseName)
        self.connection = connection
        self.services = services
        self.autoPanClock = autoPanClock
        objectChangeCancellable = AppCommands.shared.objectChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                self?.placeCreatedTable(change)
            }
    }

    deinit {
        autoPanTask?.cancel()
        layoutTask?.cancel()
    }

    // MARK: - Loading

    func loadDiagram() async {
        if let inFlight = loadTask {
            Self.logger.debug("ER diagram load already in flight, awaiting it")
            await inFlight.value
            return
        }
        guard loadState != .loaded else { return }
        let task = Task {
            await fetchAndLayOutDiagram()
            loadTask = nil
        }
        loadTask = task
        await task.value
    }

    private func fetchAndLayOutDiagram() async {
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
            let (fetched, kinds) = try await fetchGraph(in: scope)
            fullGraph = fetched
            objectKinds = kinds ?? [:]

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
            viewport.fitToWindowOnceLaidOut()

            Self.logger.debug("ER diagram loaded: \(self.graph.nodes.count) tables, \(self.graph.edges.count) edges")
        } catch {
            Self.logger.error("Failed to load ER diagram: \(error.localizedDescription)")
            loadState = .failed(error.localizedDescription)
        }
    }

    private func fetchGraph(
        in scope: DatabaseScope
    ) async throws -> (ERDiagramGraph, [String: TableInfo.TableType]?) {
        let (columns, foreignKeys, indexes, tables) = try await services.databaseManager.withMetadataDriver(
            scope: scope, workload: .bulk
        ) { driver in
            let cols = try await driver.fetchAllColumns()
            let fks = try await driver.fetchAllForeignKeys()
            let idx = try await driver.fetchIndexes(forTables: Array(fks.keys))
            // Nil keeps the kinds already known, so a failed read never turns a view into a table.
            let tables: [TableInfo]?
            do {
                tables = try await driver.fetchTables()
            } catch {
                Self.logger.error("ER diagram could not read object kinds: \(error.localizedDescription)")
                tables = nil
            }
            return (cols, fks, idx, tables)
        }
        let kinds = tables.map { Dictionary($0.map { ($0.name, $0.type) }, uniquingKeysWith: { first, _ in first }) }
        return (
            ERDiagramGraphBuilder.build(allColumns: columns, allForeignKeys: foreignKeys, allIndexes: indexes),
            kinds
        )
    }

    // MARK: - Refresh

    // Fetched before anything is replaced, so a failed refresh leaves the diagram as it was.
    func refresh() async {
        guard loadState == .loaded else {
            await loadDiagram()
            return
        }
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequested = false
            await refetchKeepingLayout()
        } while refreshRequested
    }

    private func refetchKeepingLayout() async {
        guard let scope, services.databaseManager.driver(for: connectionId) != nil else {
            presentRefreshFailure(String(localized: "No database connection"))
            return
        }
        do {
            let (fetched, kinds) = try await fetchGraph(in: scope)
            fullGraph = fetched
            if let kinds {
                objectKinds = kinds
            }
            nodeIdToName = Dictionary(uniqueKeysWithValues: fetched.nodes.map { ($0.id, $0.tableName) })
            editsStorage?.forgetUnedited()
            let visibleGraph = makeVisibleGraph()
            placeNewNodes(of: visibleGraph)
            graph = visibleGraph
            if let selected = selectedNodeId, visibleGraph.nodes.allSatisfy({ $0.id != selected }) {
                selectedNodeId = nil
            }
            if let selected = selectedEdgeId, visibleGraph.edges.allSatisfy({ $0.id != selected }) {
                selectedEdgeId = nil
            }
            invalidateCachedRects()
            persistPositions()
        } catch {
            Self.logger.error("Failed to refresh ER diagram: \(error.localizedDescription)")
            presentRefreshFailure(error.localizedDescription)
        }
    }

    private func presentRefreshFailure(_ message: String) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Could Not Refresh the Diagram"),
            message: message,
            window: coordinator?.contentWindow
        )
    }

    // A new table goes beside what is drawn, so nothing the user arranged moves.
    private func placeNewNodes(of visibleGraph: ERDiagramGraph) {
        let newNodes = visibleGraph.nodes.filter { computedLayout[$0.id] == nil && positionOverrides[$0.id] == nil }
        guard !newNodes.isEmpty else { return }

        let placed = cachedNodeRects.values
        let originX = (placed.map(\.maxX).max() ?? 0) + ERDiagramLayout.horizontalGap
        var nextY = placed.map(\.minY).min() ?? ERDiagramLayout.verticalGap
        var layout = computedLayout
        for node in newNodes {
            let height = ERDiagramLayout.estimateHeight(columnCount: node.displayColumns.count)
            if let placement = pendingPlacement, placement.tableName == node.tableName {
                positionOverrides[node.id] = placement.point
                pendingPlacement = nil
                continue
            }
            layout[node.id] = CGPoint(x: originX + ERDiagramLayout.nodeWidth / 2, y: nextY + height / 2)
            nextY += height + ERDiagramLayout.verticalGap
        }
        computedLayout = layout
    }

    // Create Table names the table it made in this notice, so the diagram can tell it from the rest.
    private func placeCreatedTable(_ change: DatabaseObjectChange) {
        guard var placement = pendingPlacement, placement.tableName == nil,
              change.connectionId == connectionId,
              loadState == .loaded,
              fullGraph.nodeIndex[change.name] == nil,
              change.scope.database == (scope?.database ?? databaseName),
              change.scope.schema?.nilIfEmpty == scope?.schema?.nilIfEmpty
        else { return }
        switch change.kind {
        case .dropped, .renamed:
            return
        case .rows, .structure, .comment:
            break
        }
        placement.tableName = change.name
        pendingPlacement = placement
        Task { await refresh() }
    }

    private func waitForConnection() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let cancellableBox = OSAllocatedUnfairLock<AnyCancellable?>(uncheckedState: nil)
            let timeoutTaskBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

            @Sendable func resumeOnce() {
                let alreadyResumed = resumed.withLock { value -> Bool in
                    if value { return true }
                    value = true
                    return false
                }
                guard !alreadyResumed else { return }
                timeoutTaskBox.withLock { $0?.cancel(); $0 = nil }
                cancellableBox.withLockUnchecked { $0 = nil }
                continuation.resume()
            }

            let targetId = self.connectionId
            let cancellable = services.appEvents.databaseDidConnect
                .receive(on: RunLoop.main)
                .sink { payload in
                    guard payload.connectionId == targetId else { return }
                    resumeOnce()
                }
            cancellableBox.withLockUnchecked { $0 = cancellable }

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(10))
                resumeOnce()
            }
            timeoutTaskBox.withLock { $0 = timeoutTask }
        }
    }

    // MARK: - Position Management

    func position(for nodeId: UUID) -> CGPoint {
        clamped(positionOverrides[nodeId] ?? computedLayout[nodeId] ?? .zero, nodeId: nodeId)
    }

    /// The canvas starts at the origin and only ever grows at its far edges, so a node centred
    /// above or to the left of it lands outside: nothing paints there and the scroll view cannot
    /// reach it. Clamping on read rather than only on write covers the three ways a node gets
    /// there: a drag, a position saved by an older build, and a node at the top edge growing
    /// taller when it leaves compact mode.
    private func clamped(_ position: CGPoint, nodeId: UUID) -> CGPoint {
        let height = ERDiagramLayout.estimateHeight(columnCount: columnCountByNodeId[nodeId] ?? 1)
        return CGPoint(
            x: max(position.x, ERDiagramLayout.nodeWidth / 2),
            y: max(position.y, height / 2)
        )
    }

    /// Paint order, not dictionary order: the node drawn last is the one on top, so an overlapping
    /// pair resolves to the table the pointer is actually over.
    func nodeId(at point: CGPoint) -> UUID? {
        graph.nodes.reversed().first { cachedNodeRects[$0.id]?.contains(point) ?? false }?.id
    }

    @discardableResult
    func setPositionOverride(nodeId: UUID, position: CGPoint) -> CGPoint {
        let height = ERDiagramLayout.estimateHeight(columnCount: columnCountByNodeId[nodeId] ?? 1)
        let position = clamped(position, nodeId: nodeId)
        positionOverrides[nodeId] = position
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
        return position
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
        let staged = editsStorage?.tableEdits() ?? [:]
        var projected = ERDiagramStagedOverlay.apply(staged, to: fullGraph)
            .projected(collapseJunctions: collapseJunctions)
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

    // No relayout: that would move every table the user has not dragged.
    func refreshStagedOverlay() {
        let staged = editsStorage?.hasChanges ?? false
        if staged != hasStagedEdits {
            hasStagedEdits = staged
            coordinator?.toolbarState.diagramEditsRevision &+= 1
            coordinator?.refreshUnsavedIndicator()
        }
        guard loadState == .loaded else { return }
        graph = makeVisibleGraph()
        if let selected = selectedEdgeId, graph.edges.allSatisfy({ $0.id != selected }) {
            selectedEdgeId = nil
        }
        invalidateCachedRects()
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

    // MARK: - Edit Storage

    var editsIfCreated: ERDiagramSchemaEdits? { editsStorage }

    func adoptEdits(_ edits: ERDiagramSchemaEdits) {
        editsStorage = edits
    }

    var editingConnection: DatabaseConnection? {
        connection ?? services.databaseManager.session(for: connectionId)?.connection
    }

    var savedGraph: ERDiagramGraph { fullGraph }

    // Unsaved work includes an edit still waiting on its baseline, or a close would drop it unasked.
    var holdsUnsavedWork: Bool {
        hasStagedEdits || stagingCount > 0
    }

    func track(_ task: Task<Void, Never>, id: UUID) {
        stagingTasks[id] = task
        stagingCount = stagingTasks.count
    }

    func finishStaging(_ id: UUID) {
        stagingTasks.removeValue(forKey: id)
        stagingCount = stagingTasks.count
    }

    func awaitPendingStaging() async {
        while let task = stagingTasks.values.first {
            await task.value
        }
    }

    // MARK: - Canvas Size

    @Published private(set) var cachedCanvasSize = CGSize(width: 800, height: 600)
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
        cachedCanvasSize = Self.canvasSize(enclosing: rects.values)
    }

    private static func canvasSize(enclosing rects: some Collection<CGRect>) -> CGSize {
        guard !rects.isEmpty else { return CGSize(width: 800, height: 600) }
        var maxX: CGFloat = 0
        var maxY: CGFloat = 0
        for rect in rects {
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
        }
        return CGSize(width: maxX + canvasPadding, height: maxY + canvasPadding)
    }

    // MARK: - Drag & Auto-Pan

    func beginDrag(at startLocation: CGPoint) {
        isDragging = true
        draggingNodeId = nodeId(at: startLocation)
        dragNodeStart = draggingNodeId.map { position(for: $0) }
    }

    /// The translation arrives in document units and already carries any scrolling that happened
    /// since the drag began, so the accumulator only has to cover the ticks between two events.
    func updateDrag(translation: CGSize, currentPoint: CGPoint) {
        lastDragTranslation = translation
        guard let nodeId = draggingNodeId, let nodeStart = dragNodeStart else { return }

        autoPanAccum = .zero
        let applied = setPositionOverride(
            nodeId: nodeId,
            position: CGPoint(x: nodeStart.x + translation.width, y: nodeStart.y + translation.height)
        )

        // Rebasing the drag origin on whatever the clamp gave back is what lets a pointer that
        // overshot the canvas edge move the node again the moment it comes back, instead of
        // standing still until the whole overshoot has been unwound. It is a no-op when the clamp
        // did not bite, because the applied position is then the requested one.
        dragNodeStart = CGPoint(x: applied.x - translation.width, y: applied.y - translation.height)
        updateAutoPanVelocity(for: currentPoint)
    }

    func endDrag() {
        if draggingNodeId != nil {
            persistPositions()
            fitCanvasToNodes()
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
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
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
            autoPanTask = Task { [weak self, autoPanClock] in
                while !Task.isCancelled {
                    self?.autoPanTick()
                    try? await autoPanClock.sleep(for: .milliseconds(16))
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

        let requested = CGSize(width: -autoPanVelocity.x, height: -autoPanVelocity.y)
        extendCanvas(toScrollBy: requested)
        let scrolled = viewport.scrollBy(requested)
        guard scrolled != .zero else { return }
        autoPanAccum.x += scrolled.width
        autoPanAccum.y += scrolled.height

        setPositionOverride(
            nodeId: nodeId,
            position: CGPoint(
                x: nodeStart.x + lastDragTranslation.width + autoPanAccum.x,
                y: nodeStart.y + lastDragTranslation.height + autoPanAccum.y
            )
        )
    }

    /// The canvas is sized from the nodes, so at a low zoom the edge band reaches further past the
    /// dragged table than the canvas does and the view had nowhere to scroll. Growing it by the step,
    /// document included, is what lets this same tick scroll.
    private func extendCanvas(toScrollBy delta: CGSize) {
        let visible = viewport.visibleDocumentRect
        let extended = CGSize(
            width: delta.width > 0 ? max(cachedCanvasSize.width, visible.maxX + delta.width) : cachedCanvasSize.width,
            height: delta.height > 0 ? max(cachedCanvasSize.height, visible.maxY + delta.height) : cachedCanvasSize.height
        )
        guard extended != cachedCanvasSize else { return }
        cachedCanvasSize = extended
        viewport.resizeDocument(to: extended)
    }

    /// A drag only ever grows the canvas, so a table dragged out and back left empty space to scroll
    /// into that Fit to Window then fitted. On an axis scrolled away from the origin it stops at the
    /// far edge on screen, or the view would snap out from under the table just dropped. An axis at
    /// the origin shrinks to the tables, because zoomed out the pane can be far larger than the canvas.
    private func fitCanvasToNodes() {
        let visible = viewport.visibleDocumentRect
        let content = Self.canvasSize(enclosing: cachedNodeRects.values)
        cachedCanvasSize = CGSize(
            width: visible.minX > 0 ? max(content.width, visible.maxX) : content.width,
            height: visible.minY > 0 ? max(content.height, visible.maxY) : content.height
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

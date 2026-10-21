import AppKit

@MainActor
enum ERDiagramEdgeRenderer {
    private struct ResolvedEdge {
        let edge: EREdge
        let fromId: UUID
        let toId: UUID
        let fromRect: CGRect
        let toRect: CGRect
    }

    private static let strokeWidth: CGFloat = 1.5
    private static let selectedStrokeWidth: CGFloat = 3
    private static let dashPattern: [CGFloat] = [6, 4]

    struct Route {
        let edge: EREdge
        let path: CGPath
        let markers: [CGPath]
    }

    struct Colors {
        let stroke: CGColor
        let selection: CGColor
        let dropped: CGColor
    }

    static func drawEdges(
        edges: [EREdge],
        nodeRects: [UUID: CGRect],
        nodeIndex: [String: UUID],
        colors: Colors,
        selectedEdgeId: UUID?,
        on canvas: some ERDiagramCanvas
    ) {
        for route in routes(edges: edges, nodeRects: nodeRects, nodeIndex: nodeIndex) {
            let isSelected = route.edge.id == selectedEdgeId
            let color: CGColor
            if isSelected {
                color = colors.selection
            } else if route.edge.stagedEdit == .dropped {
                color = colors.dropped
            } else {
                color = colors.stroke
            }
            let isPending = route.edge.stagedEdit != nil
            // Each part is its own stroke, so a translucent edge darkens where a marker crosses it.
            for part in [route.path] + route.markers {
                let drawn = isPending ? part.copy(dashingWithPhase: 0, lengths: dashPattern) : part
                canvas.stroke(
                    drawn,
                    color: color,
                    lineWidth: isSelected ? selectedStrokeWidth : strokeWidth,
                    rounded: true
                )
            }
        }
    }

    // The topmost edge within `tolerance` of the point, in the order the edges are drawn.
    static func edgeId(
        at point: CGPoint,
        tolerance: CGFloat,
        edges: [EREdge],
        nodeRects: [UUID: CGRect],
        nodeIndex: [String: UUID]
    ) -> UUID? {
        routes(edges: edges, nodeRects: nodeRects, nodeIndex: nodeIndex)
            .reversed()
            .first { route in
                route.path.boundingBoxOfPath.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                    && route.path
                    .copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
                    .contains(point)
            }?
            .edge.id
    }

    static func routes(edges: [EREdge], nodeRects: [UUID: CGRect], nodeIndex: [String: UUID]) -> [Route] {
        let resolved: [ResolvedEdge] = edges.compactMap { edge -> ResolvedEdge? in
            guard let fromId = nodeIndex[edge.fromTable],
                  let toId = nodeIndex[edge.toTable],
                  let fromRect = nodeRects[fromId],
                  let toRect = nodeRects[toId]
            else { return nil }
            return ResolvedEdge(edge: edge, fromId: fromId, toId: toId, fromRect: fromRect, toRect: toRect)
        }

        // A self edge never takes a border port, so it stays out of the port counts.
        let pairs = resolved.filter { $0.fromId != $0.toId }
        var selfLoopIndex: [String: Int] = [:]
        var selfLoopCounts: [UUID: Int] = [:]
        for item in resolved where item.fromId == item.toId {
            selfLoopIndex[edgeKey(item)] = selfLoopCounts[item.fromId, default: 0]
            selfLoopCounts[item.fromId, default: 0] += 1
        }

        var srcCounts: [UUID: Int] = [:]
        var dstCounts: [UUID: Int] = [:]
        for item in pairs {
            srcCounts[item.fromId, default: 0] += 1
            dstCounts[item.toId, default: 0] += 1
        }

        // Ports ordered by the far end's X keep a node's edges from crossing each other.
        var edgesBySource: [UUID: [ResolvedEdge]] = [:]
        var edgesByDest: [UUID: [ResolvedEdge]] = [:]
        for item in pairs {
            edgesBySource[item.fromId, default: []].append(item)
            edgesByDest[item.toId, default: []].append(item)
        }
        for key in edgesBySource.keys {
            edgesBySource[key]?.sort { $0.toRect.midX < $1.toRect.midX }
        }
        for key in edgesByDest.keys {
            edgesByDest[key]?.sort { $0.fromRect.midX < $1.fromRect.midX }
        }

        var srcPortIndex: [String: Int] = [:]
        var dstPortIndex: [String: Int] = [:]
        for (_, group) in edgesBySource {
            for (idx, item) in group.enumerated() {
                srcPortIndex[edgeKey(item)] = idx
            }
        }
        for (_, group) in edgesByDest {
            for (idx, item) in group.enumerated() {
                dstPortIndex[edgeKey(item)] = idx
            }
        }

        return resolved.map { item in
            let key = edgeKey(item)
            let path: CGPath
            let srcPort: CGPoint
            let dstPort: CGPoint
            let cp1: CGPoint
            let cp2: CGPoint

            if item.fromId == item.toId {
                let loop = selfLoop(in: item.fromRect, index: selfLoopIndex[key] ?? 0)
                srcPort = loop.source
                dstPort = loop.destination
                cp1 = loop.sourceControl
                cp2 = loop.destinationControl
                path = loop.path
            } else {
                let (source, destination, verticalPorts) = computePorts(
                    from: item.fromRect, to: item.toRect,
                    srcIdx: srcPortIndex[key] ?? 0, srcTotal: srcCounts[item.fromId] ?? 1,
                    dstIdx: dstPortIndex[key] ?? 0, dstTotal: dstCounts[item.toId] ?? 1
                )
                let (curve, control1, control2) = bezierPath(
                    from: source, to: destination, verticalPorts: verticalPorts
                )
                srcPort = source
                dstPort = destination
                cp1 = control1
                cp2 = control2
                path = curve
            }

            return Route(
                edge: item.edge,
                path: path,
                markers: sourceMarker(cardinality: item.edge.cardinality, at: srcPort, toward: cp1)
                    + destinationMarker(cardinality: item.edge.cardinality, at: dstPort, toward: cp2)
            )
        }
    }

    private static func edgeKey(_ item: ResolvedEdge) -> String {
        "\(item.edge.fromTable).\(item.edge.fkName).\(item.edge.fromColumn)"
    }

    // MARK: - Self Loop

    struct SelfLoop {
        let source: CGPoint
        let destination: CGPoint
        let sourceControl: CGPoint
        let destinationControl: CGPoint

        var path: CGPath {
            let path = CGMutablePath()
            path.move(to: source)
            path.addCurve(to: destination, control1: sourceControl, control2: destinationControl)
            return path
        }
    }

    // Out of the trailing edge and back (TSE93 5.1.3); the reach `3 * bow * t * (1 - t)` never re-enters the node.
    static func selfLoop(in rect: CGRect, index: Int) -> SelfLoop {
        let scale = ERDiagramLayout.typeScale
        let spread = min(
            max(14 * scale, rect.height * 0.25) + CGFloat(index) * 8 * scale,
            max(8 * scale, rect.height / 2 - 8)
        )
        let bow = min(
            min(max(40 * scale, spread * 1.6), ERDiagramLayout.horizontalGap) + CGFloat(index) * 16,
            maximumBow
        )

        return SelfLoop(
            source: CGPoint(x: rect.maxX, y: rect.midY + spread),
            destination: CGPoint(x: rect.maxX, y: rect.midY - spread),
            sourceControl: CGPoint(x: rect.maxX + bow, y: rect.midY + spread),
            destinationControl: CGPoint(x: rect.maxX + bow, y: rect.midY - spread)
        )
    }

    // Keeps a nested loop inside the 80 pt of canvas padding the view model adds.
    private static let maximumBow: CGFloat = 84

    // The export crops to what is drawn, and the loop with its markers reaches past the node rect.
    static func selfLoopBounds(in rect: CGRect, index: Int) -> CGRect {
        let loop = selfLoop(in: rect, index: index)
        let apex = rect.maxX + (loop.sourceControl.x - rect.maxX) * 0.75
        return CGRect(
            x: rect.maxX,
            y: loop.destination.y,
            width: apex - rect.maxX,
            height: loop.source.y - loop.destination.y
        )
        .insetBy(dx: -markerReach, dy: -markerReach)
    }

    // The crow's foot reaches 12 pt along the tangent and 8 pt across it, plus half the stroke.
    private static let markerReach: CGFloat = 14

    // MARK: - Cardinality Markers

    private static func sourceMarker(cardinality: ERCardinality, at point: CGPoint, toward target: CGPoint) -> [CGPath] {
        switch cardinality {
        case .oneToOne:
            return compoundEndMarker(at: point, toward: target, isMany: false, isMandatory: true)
        case .zeroOrOneToOne:
            return compoundEndMarker(at: point, toward: target, isMany: false, isMandatory: false)
        case .manyToOne:
            return compoundEndMarker(at: point, toward: target, isMany: true, isMandatory: true)
        case .zeroOrManyToOne:
            return compoundEndMarker(at: point, toward: target, isMany: true, isMandatory: false)
        case .manyToMany:
            return [crowFoot(at: point, toward: target)]
        }
    }

    private static func destinationMarker(cardinality: ERCardinality, at point: CGPoint, toward target: CGPoint) -> [CGPath] {
        switch cardinality {
        case .manyToMany:
            return [crowFoot(at: point, toward: target)]
        default:
            return [oneBar(at: point, toward: target)]
        }
    }

    private static func compoundEndMarker(
        at point: CGPoint,
        toward target: CGPoint,
        isMany: Bool,
        isMandatory: Bool
    ) -> [CGPath] {
        let outer = isMany ? crowFoot(at: point, toward: target) : oneBar(at: point, toward: target)

        let angle = atan2(target.y - point.y, target.x - point.x)
        let innerOffset: CGFloat = 14
        let innerPoint = CGPoint(x: point.x + innerOffset * cos(angle), y: point.y + innerOffset * sin(angle))
        let inner = isMandatory ? oneBar(at: innerPoint, toward: target) : circle(at: innerPoint)

        return [outer, inner]
    }

    private static func circle(at point: CGPoint) -> CGPath {
        let radius: CGFloat = 3.5
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        return CGPath(ellipseIn: rect, transform: nil)
    }

    // MARK: - Port Selection

    // Vertical ports only when the gap between the closest edges leaves room for a clean curve.
    static func computePorts(
        from fromRect: CGRect, to toRect: CGRect,
        srcIdx: Int, srcTotal: Int,
        dstIdx: Int, dstTotal: Int
    ) -> (CGPoint, CGPoint, Bool) {
        let fromCenter = CGPoint(x: fromRect.midX, y: fromRect.midY)
        let toCenter = CGPoint(x: toRect.midX, y: toRect.midY)

        let verticalGap: CGFloat
        if fromCenter.y < toCenter.y {
            verticalGap = toRect.minY - fromRect.maxY
        } else {
            verticalGap = fromRect.minY - toRect.maxY
        }

        let minGapForVertical: CGFloat = 30

        if verticalGap > minGapForVertical {
            let srcX = spreadOffset(in: fromRect.width, index: srcIdx, total: srcTotal, base: fromRect.minX)
            let dstX = spreadOffset(in: toRect.width, index: dstIdx, total: dstTotal, base: toRect.minX)
            if fromCenter.y < toCenter.y {
                return (CGPoint(x: srcX, y: fromRect.maxY), CGPoint(x: dstX, y: toRect.minY), true)
            } else {
                return (CGPoint(x: srcX, y: fromRect.minY), CGPoint(x: dstX, y: toRect.maxY), true)
            }
        } else {
            let srcY = spreadOffset(in: fromRect.height, index: srcIdx, total: srcTotal, base: fromRect.minY)
            let dstY = spreadOffset(in: toRect.height, index: dstIdx, total: dstTotal, base: toRect.minY)
            if fromCenter.x < toCenter.x {
                return (CGPoint(x: fromRect.maxX, y: srcY), CGPoint(x: toRect.minX, y: dstY), false)
            } else {
                return (CGPoint(x: fromRect.minX, y: srcY), CGPoint(x: toRect.maxX, y: dstY), false)
            }
        }
    }

    private static func spreadOffset(in length: CGFloat, index: Int, total: Int, base: CGFloat) -> CGFloat {
        let padding: CGFloat = min(length * 0.2, 30)
        let usable = length - padding * 2
        if total <= 1 { return base + length / 2 }
        let step = usable / CGFloat(total - 1)
        return base + padding + step * CGFloat(index)
    }

    // MARK: - Bezier Path

    static func bezierPath(from src: CGPoint, to dst: CGPoint, verticalPorts: Bool) -> (CGPath, CGPoint, CGPoint) {
        let cp1: CGPoint
        let cp2: CGPoint

        if verticalPorts {
            let offset = max(abs(dst.y - src.y) * 0.4, 20)
            cp1 = CGPoint(x: src.x, y: src.y + (dst.y > src.y ? offset : -offset))
            cp2 = CGPoint(x: dst.x, y: dst.y + (src.y > dst.y ? offset : -offset))
        } else {
            let offset = max(abs(dst.x - src.x) * 0.4, 20)
            cp1 = CGPoint(x: src.x + (dst.x > src.x ? offset : -offset), y: src.y)
            cp2 = CGPoint(x: dst.x + (src.x > dst.x ? offset : -offset), y: dst.y)
        }

        let path = CGMutablePath()
        path.move(to: src)
        path.addCurve(to: dst, control1: cp1, control2: cp2)
        return (path, cp1, cp2)
    }

    // MARK: - Crow's Foot (Many Side)

    private static func crowFoot(at point: CGPoint, toward target: CGPoint) -> CGPath {
        let length: CGFloat = 12
        let spread: CGFloat = 8
        let angle = atan2(target.y - point.y, target.x - point.x)

        let tip = CGPoint(x: point.x + length * cos(angle), y: point.y + length * sin(angle))
        let perpAngle = angle + .pi / 2

        let top = CGPoint(x: point.x + spread * cos(perpAngle), y: point.y + spread * sin(perpAngle))
        let bottom = CGPoint(x: point.x - spread * cos(perpAngle), y: point.y - spread * sin(perpAngle))

        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: top)
        path.move(to: tip)
        path.addLine(to: point)
        path.move(to: tip)
        path.addLine(to: bottom)
        return path
    }

    // MARK: - One Bar (PK Side)

    private static func oneBar(at point: CGPoint, toward target: CGPoint) -> CGPath {
        let barWidth: CGFloat = 10
        let angle = atan2(target.y - point.y, target.x - point.x)
        let perpAngle = angle + .pi / 2

        let top = CGPoint(x: point.x + barWidth * cos(perpAngle), y: point.y + barWidth * sin(perpAngle))
        let bottom = CGPoint(x: point.x - barWidth * cos(perpAngle), y: point.y - barWidth * sin(perpAngle))

        let path = CGMutablePath()
        path.move(to: top)
        path.addLine(to: bottom)
        return path
    }
}

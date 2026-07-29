import SwiftUI

/// Renders FK edges with crow's foot notation on a Canvas GraphicsContext.
enum ERDiagramEdgeRenderer {
    private struct ResolvedEdge {
        let edge: EREdge
        let fromId: UUID
        let toId: UUID
        let fromRect: CGRect
        let toRect: CGRect
    }

    static func drawEdges(
        context: GraphicsContext,
        edges: [EREdge],
        nodeRects: [UUID: CGRect],
        nodeIndex: [String: UUID]
    ) {
        let strokeColor = Color.secondary.opacity(0.7)
        let strokeStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

        // Resolve edges to IDs and rects, assign port indices sorted by X to minimize crossings
        let resolved: [ResolvedEdge] = edges.compactMap { edge -> ResolvedEdge? in
            guard let fromId = nodeIndex[edge.fromTable],
                  let toId = nodeIndex[edge.toTable],
                  let fromRect = nodeRects[fromId],
                  let toRect = nodeRects[toId]
            else { return nil }
            return ResolvedEdge(edge: edge, fromId: fromId, toId: toId, fromRect: fromRect, toRect: toRect)
        }

        var srcCounts: [UUID: Int] = [:]
        var dstCounts: [UUID: Int] = [:]
        for item in resolved {
            srcCounts[item.fromId, default: 0] += 1
            dstCounts[item.toId, default: 0] += 1
        }

        // Group by source, sort each group by destination X → left dest gets left port
        var edgesBySource: [UUID: [ResolvedEdge]] = [:]
        var edgesByDest: [UUID: [ResolvedEdge]] = [:]
        for item in resolved {
            edgesBySource[item.fromId, default: []].append(item)
            edgesByDest[item.toId, default: []].append(item)
        }
        for key in edgesBySource.keys {
            edgesBySource[key]?.sort { $0.toRect.midX < $1.toRect.midX }
        }
        for key in edgesByDest.keys {
            edgesByDest[key]?.sort { $0.fromRect.midX < $1.fromRect.midX }
        }

        // Build port indices from sorted order
        var srcPortIndex: [String: Int] = [:]
        var dstPortIndex: [String: Int] = [:]
        for (_, group) in edgesBySource {
            for (idx, item) in group.enumerated() {
                let edgeKey = "\(item.edge.fromTable).\(item.edge.fkName).\(item.edge.fromColumn)"
                srcPortIndex[edgeKey] = idx
            }
        }
        for (_, group) in edgesByDest {
            for (idx, item) in group.enumerated() {
                let edgeKey = "\(item.edge.fromTable).\(item.edge.fkName).\(item.edge.fromColumn)"
                dstPortIndex[edgeKey] = idx
            }
        }

        for item in resolved {
            let edgeKey = "\(item.edge.fromTable).\(item.edge.fkName).\(item.edge.fromColumn)"
            let si = srcPortIndex[edgeKey] ?? 0
            let di = dstPortIndex[edgeKey] ?? 0

            let (srcPort, dstPort, verticalPorts) = computePorts(
                from: item.fromRect, to: item.toRect,
                srcIdx: si, srcTotal: srcCounts[item.fromId] ?? 1,
                dstIdx: di, dstTotal: dstCounts[item.toId] ?? 1
            )
            let (path, cp1, cp2) = bezierPath(from: srcPort, to: dstPort, verticalPorts: verticalPorts)

            context.stroke(path, with: .color(strokeColor), style: strokeStyle)
            drawSourceMarker(context: context, cardinality: item.edge.cardinality, at: srcPort, toward: cp1, color: strokeColor)
            drawDestinationMarker(context: context, cardinality: item.edge.cardinality, at: dstPort, toward: cp2, color: strokeColor)
        }
    }

    // MARK: - Cardinality Markers

    private static func drawSourceMarker(
        context: GraphicsContext,
        cardinality: ERCardinality,
        at point: CGPoint,
        toward target: CGPoint,
        color: Color
    ) {
        switch cardinality {
        case .oneToOne:
            drawCompoundEndMarker(context: context, at: point, toward: target, isMany: false, isMandatory: true, color: color)
        case .zeroOrOneToOne:
            drawCompoundEndMarker(context: context, at: point, toward: target, isMany: false, isMandatory: false, color: color)
        case .manyToOne:
            drawCompoundEndMarker(context: context, at: point, toward: target, isMany: true, isMandatory: true, color: color)
        case .zeroOrManyToOne:
            drawCompoundEndMarker(context: context, at: point, toward: target, isMany: true, isMandatory: false, color: color)
        case .manyToMany:
            drawCrowFoot(context: context, at: point, toward: target, color: color)
        default:
            drawCompoundEndMarker(context: context, at: point, toward: target, isMany: true, isMandatory: true, color: color)
        }
    }

    private static func drawDestinationMarker(
        context: GraphicsContext,
        cardinality: ERCardinality,
        at point: CGPoint,
        toward target: CGPoint,
        color: Color
    ) {
        switch cardinality {
        case .manyToMany:
            drawCrowFoot(context: context, at: point, toward: target, color: color)
        default:
            drawOneBar(context: context, at: point, toward: target, color: color)
        }
    }

    private static func drawCompoundEndMarker(
        context: GraphicsContext,
        at point: CGPoint,
        toward target: CGPoint,
        isMany: Bool,
        isMandatory: Bool,
        color: Color
    ) {
        if isMany {
            drawCrowFoot(context: context, at: point, toward: target, color: color)
        } else {
            drawOneBar(context: context, at: point, toward: target, color: color)
        }

        let angle = atan2(target.y - point.y, target.x - point.x)
        let innerOffset: CGFloat = 14
        let innerPoint = CGPoint(x: point.x + innerOffset * cos(angle), y: point.y + innerOffset * sin(angle))

        if isMandatory {
            drawOneBar(context: context, at: innerPoint, toward: target, color: color)
        } else {
            drawCircle(context: context, at: innerPoint, color: color)
        }
    }

    private static func drawCircle(context: GraphicsContext, at point: CGPoint, color: Color) {
        let radius: CGFloat = 3.5
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(color), style: StrokeStyle(lineWidth: 1.5))
    }

    // MARK: - Port Selection

    /// Top-to-bottom Sugiyama layout: edges exit from bottom, enter from top.
    /// Multiple edges on the same table are spaced evenly along the edge.
    /// Returns (srcPort, dstPort, verticalPorts).
    /// Uses actual port-to-port gap to decide routing direction.
    private static func computePorts(
        from fromRect: CGRect, to toRect: CGRect,
        srcIdx: Int, srcTotal: Int,
        dstIdx: Int, dstTotal: Int
    ) -> (CGPoint, CGPoint, Bool) {
        let fromCenter = CGPoint(x: fromRect.midX, y: fromRect.midY)
        let toCenter = CGPoint(x: toRect.midX, y: toRect.midY)

        // Measure the actual gap between the closest edges (not centers)
        let verticalGap: CGFloat
        if fromCenter.y < toCenter.y {
            verticalGap = toRect.minY - fromRect.maxY
        } else {
            verticalGap = fromRect.minY - toRect.maxY
        }

        // Use vertical (bottom→top) ports only when there's enough gap for clean routing.
        // When tables overlap vertically or are too close, use side ports.
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

    /// Distributes N ports evenly along an edge, with padding from corners.
    private static func spreadOffset(in length: CGFloat, index: Int, total: Int, base: CGFloat) -> CGFloat {
        let padding: CGFloat = min(length * 0.2, 30)
        let usable = length - padding * 2
        if total <= 1 { return base + length / 2 }
        let step = usable / CGFloat(total - 1)
        return base + padding + step * CGFloat(index)
    }

    // MARK: - Bezier Path

    private static func bezierPath(from src: CGPoint, to dst: CGPoint, verticalPorts: Bool) -> (Path, CGPoint, CGPoint) {
        let cp1: CGPoint
        let cp2: CGPoint

        if verticalPorts {
            // Bottom→top ports: control points are directly below src / above dst
            let offset = max(abs(dst.y - src.y) * 0.4, 20)
            cp1 = CGPoint(x: src.x, y: src.y + (dst.y > src.y ? offset : -offset))
            cp2 = CGPoint(x: dst.x, y: dst.y + (src.y > dst.y ? offset : -offset))
        } else {
            // Side ports: control points are horizontally offset from src/dst
            let offset = max(abs(dst.x - src.x) * 0.4, 20)
            cp1 = CGPoint(x: src.x + (dst.x > src.x ? offset : -offset), y: src.y)
            cp2 = CGPoint(x: dst.x + (src.x > dst.x ? offset : -offset), y: dst.y)
        }

        var path = Path()
        path.move(to: src)
        path.addCurve(to: dst, control1: cp1, control2: cp2)
        return (path, cp1, cp2)
    }

    // MARK: - Crow's Foot (Many Side)

    private static func drawCrowFoot(context: GraphicsContext, at point: CGPoint, toward target: CGPoint, color: Color) {
        let length: CGFloat = 12
        let spread: CGFloat = 8
        let angle = atan2(target.y - point.y, target.x - point.x)

        let tipX = point.x + length * cos(angle)
        let tipY = point.y + length * sin(angle)

        let perpAngle = angle + .pi / 2

        // Three prongs from the tip back to spread points
        let top = CGPoint(x: point.x + spread * cos(perpAngle), y: point.y + spread * sin(perpAngle))
        let bottom = CGPoint(x: point.x - spread * cos(perpAngle), y: point.y - spread * sin(perpAngle))

        var path = Path()
        path.move(to: CGPoint(x: tipX, y: tipY))
        path.addLine(to: top)
        path.move(to: CGPoint(x: tipX, y: tipY))
        path.addLine(to: point)
        path.move(to: CGPoint(x: tipX, y: tipY))
        path.addLine(to: bottom)

        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    // MARK: - One Bar (PK Side)

    private static func drawOneBar(context: GraphicsContext, at point: CGPoint, toward target: CGPoint, color: Color) {
        let barWidth: CGFloat = 10
        let angle = atan2(target.y - point.y, target.x - point.x)
        let perpAngle = angle + .pi / 2

        let top = CGPoint(x: point.x + barWidth * cos(perpAngle), y: point.y + barWidth * sin(perpAngle))
        let bottom = CGPoint(x: point.x - barWidth * cos(perpAngle), y: point.y - barWidth * sin(perpAngle))

        var path = Path()
        path.move(to: top)
        path.addLine(to: bottom)

        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }
}

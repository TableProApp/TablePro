//
//  QueryPlanDiagramView.swift
//  TablePro
//
//  Canvas-based EXPLAIN plan diagram with boxes and arrows.
//

import SwiftUI

// MARK: - Layout Constants

private enum PlanLayout {
    static let nodeWidth: CGFloat = 200
    static let nodeMinHeight: CGFloat = 50
    static let horizontalSpacing: CGFloat = 24
    static let verticalSpacing: CGFloat = 40
    static let nodePadding: CGFloat = 8
    static let cornerRadius: CGFloat = 6
    static let arrowHeadSize: CGFloat = 6
}

// MARK: - Positioned Node

private struct PositionedNode: Identifiable {
    let id: UUID
    let node: QueryPlanNode
    let rect: CGRect
    let parentId: UUID?
}

// MARK: - Diagram View

struct QueryPlanDiagramView: View {
    let plan: QueryPlan

    @State private var magnification: CGFloat = 1.0
    @State private var selectedNode: SelectedNodeID?
    @State private var positioned: [PositionedNode] = []
    @State private var canvasSize = CGSize(width: 400, height: 300)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        drawArrows(context: context, nodes: positioned)
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)

                    ForEach(positioned) { pos in
                        diagramNode(pos)
                            .popover(isPresented: popoverBinding(for: pos.id)) {
                                if let node = findNode(pos.id, in: plan.rootNode) {
                                    nodeDetailPopover(node)
                                }
                            }
                            .position(x: pos.rect.midX, y: pos.rect.midY)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .scaleEffect(magnification)
                .frame(
                    width: canvasSize.width * magnification,
                    height: canvasSize.height * magnification,
                    alignment: .topLeading
                )
            }

            zoomControls
                .padding(12)
        }
        .onAppear {
            let nodes = layoutNodes(plan.rootNode, depth: 0, xOffset: 0, parentId: nil)
            positioned = nodes
            canvasSize = calculateCanvasSize(nodes)
        }
    }

    // MARK: - Node

    private func diagramNode(_ pos: PositionedNode) -> some View {
        let node = pos.node
        let isSelected = selectedNode?.id == pos.id

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(node.operation)
                    .font(.system(.callout, weight: .semibold))
                    .lineLimit(1)
                if let joinType = node.properties["Join Type"] {
                    Text(joinType)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let relation = node.relation {
                Text(relation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                if let startup = node.estimatedStartupCost, let total = node.estimatedTotalCost {
                    Text(String(format: "%.1f..%.1f", startup, total))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let rows = node.estimatedRows {
                    Text("\(rows) rows")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if let time = node.actualTotalTime {
                Text(String(format: "%.3fms", time))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(PlanLayout.nodePadding)
        .frame(width: PlanLayout.nodeWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PlanLayout.cornerRadius)
                .fill(nodeColor(fraction: node.costFraction).opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PlanLayout.cornerRadius)
                .stroke(
                    isSelected ? Color.accentColor : nodeColor(fraction: node.costFraction),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .onTapGesture { selectedNode = SelectedNodeID(id: pos.id) }
        .accessibilityLabel("\(node.operation)\(node.relation.map { " on \($0)" } ?? "")")
    }

    // MARK: - Zoom

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { magnification = max(0.25, magnification - 0.25) } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel(String(localized: "Zoom out"))
            .help(String(localized: "Zoom out"))

            Text("\(Int(magnification * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36)

            Button { magnification = min(3.0, magnification + 0.25) } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel(String(localized: "Zoom in"))
            .help(String(localized: "Zoom in"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Color

    private func nodeColor(fraction: Double) -> Color {
        if fraction > 0.5 { return .red }
        if fraction > 0.2 { return .orange }
        if fraction > 0.05 { return .yellow }
        return .green
    }

    // MARK: - Layout

    private func layoutNodes(
        _ node: QueryPlanNode, depth: Int, xOffset: CGFloat, parentId: UUID?
    ) -> [PositionedNode] {
        let nodeHeight = estimateNodeHeight(node)
        var result: [PositionedNode] = []

        if node.children.isEmpty {
            let rect = CGRect(
                x: xOffset + PlanLayout.horizontalSpacing,
                y: CGFloat(depth) * (nodeHeight + PlanLayout.verticalSpacing) + PlanLayout.verticalSpacing,
                width: PlanLayout.nodeWidth,
                height: nodeHeight
            )
            result.append(PositionedNode(id: node.id, node: node, rect: rect, parentId: parentId))
        } else {
            var childPositions: [PositionedNode] = []
            var currentX = xOffset

            for child in node.children {
                let childNodes = layoutNodes(child, depth: depth + 1, xOffset: currentX, parentId: node.id)
                let childWidth = subtreeWidth(childNodes)
                currentX += childWidth + PlanLayout.horizontalSpacing
                childPositions.append(contentsOf: childNodes)
            }

            let firstChildX = childPositions.first { $0.parentId == node.id }?.rect.midX ?? xOffset
            let lastChildX = childPositions.last { $0.parentId == node.id }?.rect.midX ?? xOffset
            let centerX = (firstChildX + lastChildX) / 2

            let rect = CGRect(
                x: centerX - PlanLayout.nodeWidth / 2,
                y: CGFloat(depth) * (nodeHeight + PlanLayout.verticalSpacing) + PlanLayout.verticalSpacing,
                width: PlanLayout.nodeWidth,
                height: nodeHeight
            )
            result.append(PositionedNode(id: node.id, node: node, rect: rect, parentId: parentId))
            result.append(contentsOf: childPositions)
        }

        return result
    }

    private func estimateNodeHeight(_ node: QueryPlanNode) -> CGFloat {
        var h: CGFloat = 18
        if node.relation != nil { h += 14 }
        if node.estimatedTotalCost != nil || node.estimatedRows != nil { h += 12 }
        if node.actualTotalTime != nil { h += 12 }
        return max(PlanLayout.nodeMinHeight, h + PlanLayout.nodePadding * 2)
    }

    private func subtreeWidth(_ nodes: [PositionedNode]) -> CGFloat {
        guard let minX = nodes.map({ $0.rect.minX }).min(),
              let maxX = nodes.map({ $0.rect.maxX }).max()
        else { return PlanLayout.nodeWidth }
        return maxX - minX
    }

    private func calculateCanvasSize(_ nodes: [PositionedNode]) -> CGSize {
        let maxX = nodes.map { $0.rect.maxX }.max() ?? 400
        let maxY = nodes.map { $0.rect.maxY }.max() ?? 300
        return CGSize(
            width: maxX + PlanLayout.horizontalSpacing * 2,
            height: maxY + PlanLayout.verticalSpacing * 2
        )
    }

    // MARK: - Arrows

    private func drawArrows(context: GraphicsContext, nodes: [PositionedNode]) {
        let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        for node in nodes {
            guard let parentId = node.parentId, let parent = nodeMap[parentId] else { continue }

            let start = CGPoint(x: parent.rect.midX, y: parent.rect.maxY)
            let end = CGPoint(x: node.rect.midX, y: node.rect.minY)
            let midY = (start.y + end.y) / 2

            var path = Path()
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x, y: midY), control2: CGPoint(x: end.x, y: midY))
            context.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 1)

            var arrow = Path()
            let s = PlanLayout.arrowHeadSize
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(x: end.x - s, y: end.y - s))
            arrow.addLine(to: CGPoint(x: end.x + s, y: end.y - s))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(.secondary.opacity(0.4)))
        }
    }

    // MARK: - Popover

    private static let hiddenKeys: Set<String> = [
        "Parallel Aware", "Async Capable", "Disabled", "Inner Unique",
    ]

    private func nodeDetailPopover(_ node: QueryPlanNode) -> some View {
        let filtered = node.properties
            .filter { !Self.hiddenKeys.contains($0.key) }
            .filter { $0.value != "false" && $0.value != "0" }
            .sorted { $0.key < $1.key }

        return VStack(alignment: .leading, spacing: 6) {
            Text(node.operation)
                .font(.headline)

            if let relation = node.relation { detailRow("Table", relation) }
            if let s = node.estimatedStartupCost, let t = node.estimatedTotalCost {
                detailRow("Cost", String(format: "%.2f..%.2f", s, t))
            }
            if let rows = node.estimatedRows { detailRow("Rows", "\(rows)") }
            if let width = node.estimatedWidth, width > 0 { detailRow("Width", "\(width)") }

            if let time = node.actualTotalTime {
                Divider()
                detailRow("Actual Time", String(format: "%.3fms", time))
                if let rows = node.actualRows { detailRow("Actual Rows", "\(rows)") }
                if let loops = node.actualLoops, loops > 1 { detailRow("Loops", "\(loops)") }
            }

            if !filtered.isEmpty {
                Divider()
                ForEach(filtered, id: \.key) { key, value in
                    detailRow(key, value)
                }
            }
        }
        .padding()
        .frame(minWidth: 240)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    // MARK: - Popover Binding

    private func popoverBinding(for nodeId: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedNode?.id == nodeId },
            set: { if !$0 { selectedNode = nil } }
        )
    }

    // MARK: - Find Node

    private func findNode(_ id: UUID?, in node: QueryPlanNode) -> QueryPlanNode? {
        guard let id else { return nil }
        if node.id == id { return node }
        for child in node.children {
            if let found = findNode(id, in: child) { return found }
        }
        return nil
    }
}

// MARK: - Identifiable Wrapper

private struct SelectedNodeID: Identifiable {
    let id: UUID
}

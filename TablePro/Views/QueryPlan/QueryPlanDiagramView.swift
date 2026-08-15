//
//  QueryPlanDiagramView.swift
//  TablePro
//
//  Canvas-based EXPLAIN plan diagram with boxes and arrows.
//

import SwiftUI

// MARK: - Diagram View

struct QueryPlanDiagramView: View {
    @State private var magnification: CGFloat = 1.0
    @State private var selectedNodeId: UUID?
    @GestureState private var pinchMagnification: CGFloat = 1.0

    /// Derived from the plan on every update, so a second EXPLAIN in the same tab redraws
    /// instead of keeping the layout the first one produced.
    private let layout: QueryPlanDiagramLayout

    init(plan: QueryPlan) {
        layout = QueryPlanDiagramLayout(root: plan.rootNode)
    }

    private var effectiveMagnification: CGFloat {
        DiagramZoom.scaled(from: magnification, by: pinchMagnification)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        drawArrows(context: context)
                    }
                    .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)

                    ForEach(layout.nodes) { positioned in
                        diagramNode(positioned)
                            .popover(isPresented: detailBinding(for: positioned.id)) {
                                nodeDetailPopover(positioned.node)
                            }
                            .position(x: positioned.rect.midX, y: positioned.rect.midY)
                    }
                }
                .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
                .scaleEffect(effectiveMagnification, anchor: .topLeading)
                .frame(
                    width: layout.canvasSize.width * effectiveMagnification,
                    height: layout.canvasSize.height * effectiveMagnification,
                    alignment: .topLeading
                )
            }

            zoomControls
                .padding(12)
        }
        .simultaneousGesture(magnifyGesture)
    }

    // MARK: - Node

    private func diagramNode(_ positioned: QueryPlanDiagramLayout.Node) -> some View {
        let node = positioned.node
        let isSelected = selectedNodeId == positioned.id

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
                if let cost = node.costRangeText(fractionDigits: 1) {
                    Text(cost)
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
        .padding(QueryPlanDiagramMetrics.nodePadding)
        .frame(width: QueryPlanDiagramMetrics.nodeWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: QueryPlanDiagramMetrics.cornerRadius)
                .fill(nodeColor(fraction: node.costFraction).opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: QueryPlanDiagramMetrics.cornerRadius)
                .stroke(
                    isSelected ? Color.accentColor : nodeColor(fraction: node.costFraction),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .onTapGesture { selectedNodeId = positioned.id }
        .accessibilityLabel("\(node.operation)\(node.relation.map { " on \($0)" } ?? "")")
    }

    // MARK: - Zoom

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchMagnification) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                magnification = DiagramZoom.scaled(from: magnification, by: value.magnification)
            }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                magnification = DiagramZoom.clamped(magnification - DiagramZoom.step)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel(String(localized: "Zoom out"))
            .help(String(localized: "Zoom out"))

            Text("\(Int((effectiveMagnification * 100).rounded()))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36)

            Button {
                magnification = DiagramZoom.clamped(magnification + DiagramZoom.step)
            } label: {
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

    // MARK: - Arrows

    private func drawArrows(context: GraphicsContext) {
        let nodeMap = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })

        for node in layout.nodes {
            guard let parentId = node.parentId, let parent = nodeMap[parentId] else { continue }

            let start = CGPoint(x: parent.rect.midX, y: parent.rect.maxY)
            let end = CGPoint(x: node.rect.midX, y: node.rect.minY)
            let midY = (start.y + end.y) / 2

            var path = Path()
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x, y: midY), control2: CGPoint(x: end.x, y: midY))
            context.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 1)

            var arrow = Path()
            let size = QueryPlanDiagramMetrics.arrowHeadSize
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(x: end.x - size, y: end.y - size))
            arrow.addLine(to: CGPoint(x: end.x + size, y: end.y - size))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(.secondary.opacity(0.4)))
        }
    }

    // MARK: - Popover

    private static let hiddenKeys: Set<String> = [
        "Parallel Aware", "Async Capable", "Disabled", "Inner Unique",
    ]

    private func detailBinding(for nodeId: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedNodeId == nodeId },
            set: { if !$0 { selectedNodeId = nil } }
        )
    }

    private func nodeDetailPopover(_ node: QueryPlanNode) -> some View {
        let filtered = node.properties
            .filter { !Self.hiddenKeys.contains($0.key) }
            .filter { $0.value != "false" && $0.value != "0" }
            .sorted { $0.key < $1.key }

        return VStack(alignment: .leading, spacing: 6) {
            Text(node.operation)
                .font(.headline)

            if let relation = node.relation { detailRow("Table", relation) }
            if let cost = node.costRangeText(fractionDigits: 2) { detailRow("Cost", cost) }
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
}

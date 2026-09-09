//
//  QueryPlanDiagramView.swift
//  TablePro
//
//  EXPLAIN plan diagram: boxes and arrows on an AppKit-magnified canvas, so pan and zoom
//  behave the way every other document surface on macOS does.
//

import SwiftUI

struct QueryPlanDiagramView: View {
    @Binding var selectedNodeId: UUID?

    @State private var viewport = DiagramViewportController()

    /// Derived from the plan on every update, so a second EXPLAIN in the same tab redraws
    /// instead of keeping the layout the first one produced.
    private let layout: QueryPlanDiagramLayout

    init(plan: QueryPlan, selectedNodeId: Binding<UUID?>) {
        layout = QueryPlanDiagramLayout(root: plan.rootNode)
        _selectedNodeId = selectedNodeId
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MagnifiableCanvasView(
                viewport: viewport,
                contentSize: layout.canvasSize,
                accessibilityIdentifier: "query-plan-diagram"
            ) {
                canvas
            }

            DiagramZoomToolbar(viewport: viewport) {
                Divider().frame(height: 16)
                Button {
                    DiagramImageExporter.export(
                        exportCanvas,
                        defaultFileName: "query-plan.png",
                        title: String(localized: "Export Query Plan")
                    )
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(String(localized: "Export Plan as Image"))
                .help(String(localized: "Export Plan as Image"))
            }
            .padding(12)
        }
        .onCopyCommand { DiagramImageExporter.copyItemProviders(of: exportCanvas) }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            arrowLayer

            ForEach(layout.nodes) { positioned in
                QueryPlanDiagramNodeView(
                    node: positioned.node,
                    isSelected: selectedNodeId == positioned.id
                )
                .onTapGesture { selectedNodeId = positioned.id }
                .contextMenu { nodeContextMenu(for: positioned.node) }
                .popover(isPresented: detailBinding(for: positioned.id)) {
                    QueryPlanDetailPane(node: positioned.node)
                        .frame(minWidth: 260, maxWidth: 420)
                        .padding(4)
                }
                .position(x: positioned.rect.midX, y: positioned.rect.midY)
            }
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
    }

    /// A non-interactive copy at natural scale, so an export never captures the current zoom,
    /// scroll offset or selection.
    private var exportCanvas: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for arrow in layout.arrows {
                    context.stroke(
                        QueryPlanArrowsView.curve(arrow),
                        with: .color(QueryPlanArrowsView.color),
                        lineWidth: 1
                    )
                    context.fill(QueryPlanArrowsView.head(arrow), with: .color(QueryPlanArrowsView.color))
                }
            }
            .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)

            ForEach(layout.nodes) { positioned in
                QueryPlanDiagramNodeView(node: positioned.node, isSelected: false)
                    .position(x: positioned.rect.midX, y: positioned.rect.midY)
            }
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func nodeContextMenu(for node: QueryPlanNode) -> some View {
        Button(String(localized: "Copy Operation")) {
            ClipboardService.shared.writeText(node.operation)
        }
        Button(String(localized: "Copy Node Details")) {
            ClipboardService.shared.writeText(QueryPlanNodeSummary.text(for: node))
        }
    }

    private func detailBinding(for nodeId: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedNodeId == nodeId },
            set: { if !$0 { selectedNodeId = nil } }
        )
    }

    // MARK: - Arrows

    private var arrowLayer: some View {
        QueryPlanArrowsView(arrows: layout.arrows, size: layout.canvasSize)
    }
}

// MARK: - Arrow Layer

/// Shapes rather than a `Canvas`. A `Canvas` inside a magnifying `NSScrollView` stops painting past
/// `contentSize * magnification + 128` document points once magnification reaches 0.5, so a plan
/// zoomed out lost its arrows while its nodes, being ordinary views, stayed (#2692). The export
/// canvas is never magnified and draws the same arrows from the same geometry.
struct QueryPlanArrowsView: View {
    let arrows: [QueryPlanDiagramLayout.Arrow]
    let size: CGSize

    static let color = Color.secondary.opacity(0.4)

    static func curve(_ arrow: QueryPlanDiagramLayout.Arrow) -> Path {
        var path = Path()
        path.move(to: arrow.start)
        path.addCurve(to: arrow.end, control1: arrow.control1, control2: arrow.control2)
        return path
    }

    static func head(_ arrow: QueryPlanDiagramLayout.Arrow) -> Path {
        var path = Path()
        guard let first = arrow.head.first else { return path }
        path.move(to: first)
        for point in arrow.head.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// One shape for every curve and one for every head, rather than one view per arrow. A shape
    /// view is sized to its own path, so a per-arrow view would be laid out at its bounding box and
    /// centred, which moves the arrow off the node it points at.
    private struct Combined: Shape {
        let paths: [Path]

        func path(in rect: CGRect) -> Path {
            var combined = Path()
            for path in paths { combined.addPath(path) }
            return combined
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Combined(paths: arrows.map(Self.curve)).stroke(Self.color, lineWidth: 1)
            Combined(paths: arrows.map(Self.head)).fill(Self.color)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

// MARK: - Node

private struct QueryPlanDiagramNodeView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    let node: QueryPlanNode
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let severity = node.severity {
                    Image(systemName: severity.symbolName)
                        .font(.system(size: 7))
                        .foregroundStyle(tint)
                }
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
                    Text("\(rows) ^[rows](inflect: true)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if let time = node.actualTotalTime {
                Text(QueryPlanLabels.milliseconds(time))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(QueryPlanDiagramMetrics.nodePadding)
        .frame(width: QueryPlanDiagramMetrics.nodeWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: QueryPlanDiagramMetrics.cornerRadius)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: QueryPlanDiagramMetrics.cornerRadius)
                .stroke(isSelected ? Color.accentColor : tint, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: QueryPlanDiagramMetrics.cornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(QueryPlanNodeSummary.accessibilityLabel(for: node))
    }

    private var tint: Color {
        node.severity?.tint(differentiateWithoutColor: differentiateWithoutColor) ?? .secondary
    }
}

import SwiftUI
import TableProTheme

struct QueryPlanDiagramView: View {
    @Binding var selectedNodeId: UUID?
    @Environment(\.colorScheme) private var colorScheme

    // Owned by the plan's `QueryPlanViewState`: this view goes away on every mode switch.
    let viewport: DiagramViewportController

    // Derived on every update, so a second EXPLAIN in the same tab redraws.
    private let layout: QueryPlanDiagramLayout

    init(plan: QueryPlan, selectedNodeId: Binding<UUID?>, viewport: DiagramViewportController) {
        layout = QueryPlanDiagramLayout(root: plan.rootNode)
        _selectedNodeId = selectedNodeId
        self.viewport = viewport
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            canvas

            DiagramZoomToolbar(viewport: viewport) {
                Divider().frame(height: 16)
                Button {
                    DiagramExporter.export(
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
    }

    // MARK: - Canvas

    // The selection is read here, during `body`, so a change to it re-renders the canvas.
    private var canvas: some View {
        let layout = layout
        let selectedNodeId = selectedNodeId
        let selection = $selectedNodeId
        let exportCanvas = exportCanvas
        return MagnifiableCanvasView(
            viewport: viewport,
            contentSize: layout.canvasSize,
            accessibilityIdentifier: "query-plan-diagram",
            makeDocument: { QueryPlanDiagramCanvasView() },
            updateDocument: { canvasView in
                canvasView.update(layout: layout, selectedNodeId: selectedNodeId) { selection.wrappedValue = $0 }
                canvasView.copyImage = {
                    guard let image = DiagramExporter.image(of: exportCanvas) else { return }
                    ClipboardService.shared.writeImage(image)
                }
            }
        )
    }

    private var exportCanvas: QueryPlanDiagramExportCanvas {
        QueryPlanDiagramExportCanvas(layout: layout, colorScheme: colorScheme)
    }
}

// `ImageRenderer` draws in the light scheme whatever the window shows, so the canvas's scheme is passed in.
struct QueryPlanDiagramExportCanvas: View {
    let layout: QueryPlanDiagramLayout
    let colorScheme: ColorScheme

    var body: some View {
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
        .themeBackground(.windowBackdrop, native: Color(nsColor: .controlBackgroundColor))
        .environment(\.colorScheme, colorScheme)
    }
}

// MARK: - Drawing

// Input and accessibility belong to `QueryPlanDiagramCanvasView`.
struct QueryPlanDiagramDrawing: View {
    let layout: QueryPlanDiagramLayout
    let selectedNodeId: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            QueryPlanArrowsView(arrows: layout.arrows, size: layout.canvasSize)

            ForEach(layout.nodes) { positioned in
                QueryPlanDiagramNodeView(
                    node: positioned.node,
                    isSelected: selectedNodeId == positioned.id
                )
                .position(x: positioned.rect.midX, y: positioned.rect.midY)
            }
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
        .accessibilityHidden(true)
    }
}

// MARK: - Arrow Layer

// Shapes, not a `Canvas`: a `Canvas` in a magnified `NSScrollView` stops painting at 0.5 magnification (#2692).
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

    // A per-arrow shape view is laid out at its bounding box and centred, off the node it points at.
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

struct QueryPlanDiagramNodeView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject private var themeEngine = ThemeEngine.shared

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
                    .themeForeground(.gridText, native: .primary)
                if let joinType = node.properties["Join Type"] {
                    Text(joinType)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !node.warnings.isEmpty {
                    Spacer(minLength: 0)
                    QueryPlanWarningBadge(count: node.warnings.count)
                }
            }

            if let relation = node.relation ?? node.properties["Index Name"] {
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
                    Text("^[\(rows) row](inflect: true)")
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
        .themeBackground(
            .gridBackground,
            native: Color.clear,
            in: RoundedRectangle(cornerRadius: QueryPlanDiagramMetrics.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: QueryPlanDiagramMetrics.cornerRadius)
                .stroke(stroke, lineWidth: isSelected ? 2 : 1)
        )
    }

    private var tint: Color {
        node.severity?.tint(differentiateWithoutColor: differentiateWithoutColor) ?? .secondary
    }

    // The grid outlines its active cell with the focus border, so a selected step does too.
    private var stroke: AnyShapeStyle {
        guard isSelected else { return AnyShapeStyle(tint) }
        return ThemeShapeStyle.style(.gridFocusBorder, native: Color.accentColor, engine: themeEngine, contrast: contrast)
    }
}

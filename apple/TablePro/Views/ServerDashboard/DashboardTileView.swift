import SwiftUI
import TableProTheme

struct DashboardTileView: View {
    struct Actions {
        let setInterval: (DashboardTileInterval) -> Void
        let moveEarlier: () -> Void
        let moveLater: () -> Void
        let remove: () -> Void
        let dropTile: (UUID) -> Bool
    }

    let tile: DashboardTile
    let title: String
    let state: DashboardTileBoard.TileState
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let actions: Actions

    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(10)
        .frame(height: 168)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contextMenu { menuItems }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)), id != tile.id else { return false }
            return actions.dropTile(id)
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("server-dashboard-tile")
    }

    // The drag handle is the title row alone: a drag on a chart moves its selection, not the tile.
    private var header: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
            Spacer(minLength: 4)
            if state.isRunning {
                ProgressView()
                    .controlSize(.mini)
            }
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Tile Options"))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Tile Options"))
        }
        .contentShape(Rectangle())
        .draggable(tile.id.uuidString)
    }

    @ViewBuilder
    private var content: some View {
        if let refusal = state.refusal {
            Label {
                Text(refusal)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "hand.raised")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if let display = state.display {
            DashboardTileContentView(display: display)
        } else if let error = state.error {
            errorLabel(error, lineLimit: 5)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if state.refusal == nil, state.display != nil, let error = state.error {
            errorLabel(error, lineLimit: 1)
        } else if tile.interval != .dashboard {
            Text(tile.interval.displayLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func errorLabel(_ message: String, lineLimit: Int) -> some View {
        Label {
            RevealedTextView(message)
                .lineLimit(lineLimit)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(.red)
        .help(RevealedText(message).plainText)
    }

    @ViewBuilder
    private var menuItems: some View {
        Picker(String(localized: "Refresh"), selection: Binding(
            get: { tile.interval },
            set: { actions.setInterval($0) }
        )) {
            ForEach(DashboardTileInterval.allCases) { interval in
                Text(interval.displayLabel).tag(interval)
            }
        }
        Divider()
        Button(String(localized: "Move Left"), action: actions.moveEarlier)
            .disabled(!canMoveEarlier)
        Button(String(localized: "Move Right"), action: actions.moveLater)
            .disabled(!canMoveLater)
        Divider()
        Button(String(localized: "Remove from Dashboard"), action: actions.remove)
    }
}

private struct DashboardTileContentView: View {
    let display: DashboardTileDisplay

    var body: some View {
        switch display {
        case .value(let value):
            Text(verbatim: value)
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .table(let table):
            tableView(table)
        case .lineChart(let projection, let isTruncated):
            VStack(alignment: .leading, spacing: 2) {
                ResultChartCanvas(
                    projection: projection,
                    chartType: .line,
                    showsLegend: false,
                    accessibilityIdentifier: "server-dashboard-tile-chart"
                )
                let notices = Self.chartNotices(projection, isTruncated: isTruncated)
                if !notices.isEmpty {
                    Text(verbatim: notices.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(notices.joined(separator: "\n"))
                }
            }
        }
    }

    private static func chartNotices(_ projection: ResultChartProjection, isTruncated: Bool) -> [String] {
        let fetched = isTruncated
            ? [String(format: String(localized: "First %@ rows only"), DashboardTileTable.rowCap.formatted())]
            : []
        return fetched + ResultChartToolbar.notices(for: projection)
    }

    @ViewBuilder
    private func tableView(_ table: DashboardTileTable) -> some View {
        if table.rows.isEmpty {
            Text("No rows")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                        GridRow {
                            ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                                Text(verbatim: column)
                                    .fontWeight(.semibold)
                                    .themeForeground(.gridHeaderText, native: HierarchicalShapeStyle.secondary)
                            }
                        }
                        ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(verbatim: cell)
                                        .monospacedDigit()
                                        .themeForeground(.gridText, native: HierarchicalShapeStyle.primary)
                                }
                            }
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .padding(4)
                }
                .themeBackground(.gridBackground, native: Color.clear, in: RoundedRectangle(cornerRadius: 4))
                if table.isTruncated {
                    Text(String(
                        format: String(localized: "%1$@ of more than %2$@ rows"),
                        table.rows.count.formatted(),
                        table.totalRowCount.formatted()
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                } else if table.hiddenRowCount > 0 {
                    Text("\(table.rows.count) of ^[\(table.totalRowCount) row](inflect: true)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

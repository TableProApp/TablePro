//
//  ResultMapView.swift
//  TablePro
//

import SwiftUI
import TableProGeometry
import TableProPluginKit

struct ResultMapProjectionKey: Hashable {
    let tabId: UUID
    let resultSetId: UUID
    let dataRevision: Int
    let displayRevision: Int
    let geometryColumn: SpatialColumnID?
}

struct ResultMapView: View {
    @Binding var configuration: ResultMapConfiguration
    let tableRows: TableRows
    let displayIDs: [RowID]?
    let selectedRowIndices: Set<Int>
    let tabId: UUID
    let resultSetId: UUID
    let dataRevision: Int
    let displayRevision: Int
    let onSelectRow: (Int?) -> Void

    /// Every state the pane can be in has a branch below, so there is no combination that renders
    /// nothing. Projection is cancellable but cannot otherwise fail, which its signature enforces.
    private enum LoadState: Equatable {
        case loading
        case loaded(ResultMapProjection)
    }

    @State private var state: LoadState = .loading
    @State private var fitToken = 0

    private var columns: [SpatialColumn] {
        SpatialColumn.columns(in: tableRows)
    }

    private var resolved: SpatialColumn? {
        configuration.resolved(in: columns)
    }

    private var projectionKey: ResultMapProjectionKey {
        ResultMapProjectionKey(
            tabId: tabId,
            resultSetId: resultSetId,
            dataRevision: dataRevision,
            displayRevision: displayRevision,
            geometryColumn: resolved?.id
        )
    }

    private var loadedProjection: ResultMapProjection? {
        guard case .loaded(let projection) = state else { return nil }
        return projection
    }

    var body: some View {
        VStack(spacing: 0) {
            ResultMapToolbar(
                configuration: $configuration,
                columns: columns,
                resolved: resolved,
                status: statusText,
                canFit: !(loadedProjection?.isEmpty ?? true),
                onFit: { fitToken &+= 1 }
            )
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: projectionKey) {
            await rebuild(for: projectionKey)
        }
        .onChange(of: projectionKey) {
            fitToken &+= 1
        }
    }

    @ViewBuilder
    private var content: some View {
        if tableRows.rows.isEmpty {
            ContentUnavailableView(
                String(localized: "No Data"),
                systemImage: "map",
                description: Text(String(localized: "Execute a query to map its loaded rows."))
            )
        } else if resolved == nil {
            ContentUnavailableView(
                String(localized: "No Spatial Column"),
                systemImage: "map",
                description: Text(String(localized: "A map needs a geometry or geography column. This result has none."))
            )
        } else {
            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Building map"))
            case .loaded(let projection) where projection.isEmpty:
                ContentUnavailableView {
                    Label(String(localized: "Nothing to Draw"), systemImage: "map")
                } description: {
                    Text(emptyProjectionReason(projection))
                }
            case .loaded(let projection):
                ResultMapCanvas(
                    projection: projection,
                    projectionToken: projectionKey.hashValue,
                    selectedRowIDs: selectedRowIDs(in: projection),
                    fitToken: fitToken,
                    onSelect: select(rowID:)
                )
                .accessibilityIdentifier("result-map")
                .accessibilityLabel(accessibilityLabel(for: projection))
            }
        }
    }

    // MARK: - Status and reasons

    /// What the map is showing and what it left out, as a sentence rather than a count on its own.
    private var statusText: String {
        guard let projection = loadedProjection else { return "" }
        var parts: [String] = []
        if let srid = projection.diagnostics.drawnSRID {
            parts.append(String(
                format: String(localized: "Drawing %1$d shapes in SRID %2$d."),
                projection.diagnostics.drawnShapes,
                Int(srid)
            ))
        } else if case .assumedGeographic = projection.diagnostics.projectability {
            parts.append(String(
                format: String(localized: "Drawing %d shapes with no SRID, read as longitude and latitude."),
                projection.diagnostics.drawnShapes
            ))
        } else {
            parts.append(String(
                format: String(localized: "Drawing %d shapes."),
                projection.diagnostics.drawnShapes
            ))
        }
        if projection.diagnostics.otherSRIDRows > 0 {
            parts.append(String(
                format: String(localized: "%d rows in other coordinate systems are not drawn."),
                projection.diagnostics.otherSRIDRows
            ))
        }
        if let capped = projection.diagnostics.cappedRows {
            parts.append(String(
                format: String(localized: "%d rows are past the drawing limit."),
                capped
            ))
        }
        for (keyword, count) in projection.diagnostics.unsupportedTypes.sorted(by: { $0.key < $1.key }) {
            parts.append(String(
                format: String(localized: "%1$d rows use %2$@, which cannot be drawn."),
                count,
                keyword
            ))
        }
        if projection.diagnostics.unreadableRows > 0 {
            parts.append(String(
                format: String(localized: "%d rows could not be read."),
                projection.diagnostics.unreadableRows
            ))
        }
        return parts.joined(separator: " ")
    }

    /// Why a result with a geometry column still drew nothing. Always names the reason: a blank
    /// map with no explanation is the failure mode every competitor ships.
    private func emptyProjectionReason(_ projection: ResultMapProjection) -> String {
        if case .unsupported(let srid) = projection.diagnostics.projectability {
            if let srid {
                return String(
                    format: String(localized: """
                    SRID %d is a projected coordinate system. Maps places longitude and latitude \
                    only, so these shapes cannot be drawn. Query ST_Transform(geom, 4326) to see them.
                    """),
                    Int(srid)
                )
            }
            if projection.diagnostics.consideredRows > 0, projection.diagnostics.emptyRows == projection.diagnostics.consideredRows {
                return String(localized: "Every geometry in this column is empty or null.")
            }
            return String(localized: """
            This column carries no SRID and its coordinates are outside the range of longitude and \
            latitude, so the map cannot place them.
            """)
        }
        if !projection.diagnostics.unsupportedTypes.isEmpty {
            let names = projection.diagnostics.unsupportedTypes.keys.sorted().joined(separator: ", ")
            return String(
                format: String(localized: "This column holds %@, which the map cannot draw."),
                names
            )
        }
        return String(localized: "Every geometry in this column is empty or null.")
    }

    /// The map is one element to VoiceOver: `MKMapView` reports itself as an image and publishes no
    /// children for overlays, measured. The data grid stays the accessible representation of the
    /// rows, and this label says what the map adds.
    private func accessibilityLabel(for projection: ResultMapProjection) -> String {
        let base = String(
            format: String(localized: "Map of %1$d shapes from %2$d rows."),
            projection.diagnostics.drawnShapes,
            projection.diagnostics.drawnRows
        )
        guard !selectedRowIndices.isEmpty else { return base }
        return base + " " + String(
            format: String(localized: "%d rows selected."),
            selectedRowIndices.count
        )
    }

    // MARK: - Selection

    /// Selection crosses the mode switch through `GridSelectionState`, whose indices are display
    /// positions rather than offsets into `TableRows.rows`. A per-column value filter makes those
    /// diverge, so both directions go through `DisplayRowMapping`.
    private func selectedRowIDs(in projection: ResultMapProjection) -> Set<RowID> {
        var ids = Set<RowID>()
        for index in selectedRowIndices {
            guard let rowIndex = DisplayRowMapping.rowIndex(
                forDisplay: index,
                displayIDs: displayIDs,
                in: tableRows
            ) else {
                continue
            }
            ids.insert(tableRows.rows[rowIndex].id)
        }
        return ids
    }

    private func select(rowID: RowID?) {
        guard let rowID else {
            onSelectRow(nil)
            return
        }
        let displayIndex = DisplayRowMapping.displayIndex(
            forRowID: rowID,
            displayIDs: displayIDs,
            in: tableRows
        )
        onSelectRow(displayIndex)
    }

    // MARK: - Projection

    /// A cancelled projection leaves the state alone: `task(id:)` cancels only to start a
    /// replacement, and that replacement owns the state from its first line.
    private func rebuild(for expectedKey: ResultMapProjectionKey) async {
        guard let column = resolved else { return }
        state = .loading
        let output = await SpatialResultProjector.shared.project(
            tableRows: tableRows,
            displayIDs: displayIDs,
            column: column
        )
        guard !Task.isCancelled, projectionKey == expectedKey else { return }
        state = .loaded(output)
    }
}

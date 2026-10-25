//
//  ResultMapView.swift
//  TablePro
//

import SwiftUI
import TableProGeometry
import TableProPluginKit

struct ResultMapProjectionKey: ResultPaneProjectionKey {
    let tabId: UUID
    let resultSetId: UUID
    let dataRevision: Int
    let displayRevision: Int
    let geometryColumn: SpatialColumnID?

    struct Subject: Hashable {
        let tabId: UUID
        let geometryColumn: SpatialColumnID?
    }

    var subject: Subject {
        Subject(tabId: tabId, geometryColumn: geometryColumn)
    }
}

struct ResultMapView: View {
    @Binding var configuration: ResultMapConfiguration
    let columns: [SpatialColumn]
    let tableRows: TableRows
    let displayIDs: [RowID]?
    let selectedRowIDs: Set<RowID>
    let tabId: UUID
    let resultSetId: UUID
    let dataRevision: Int
    let displayRevision: Int
    let onSelectRow: (RowID?) -> Void

    @State private var state = ResultPaneProjectionState<ResultMapProjection, ResultMapProjectionKey>()
    @State private var fitToken = 0

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

    private var shownProjection: ResultMapProjection? {
        guard resolved != nil else { return nil }
        return state.projection(for: projectionKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            ResultMapToolbar(
                configuration: $configuration,
                columns: columns,
                resolved: resolved,
                status: shownProjection?.diagnostics.statusText ?? "",
                canFit: !(shownProjection?.isEmpty ?? true),
                onFit: { fitToken &+= 1 }
            )
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: projectionKey) {
            await rebuild(for: projectionKey)
        }
    }

    @ViewBuilder
    private var content: some View {
        if tableRows.rows.isEmpty {
            UnavailableStateView(
                String(localized: "No Data"),
                systemImage: "map",
                description: Text(String(localized: "Execute a query to map its loaded rows."))
            )
        } else if resolved == nil {
            UnavailableStateView(
                String(localized: "No Spatial Column"),
                systemImage: "map",
                description: Text(String(localized: "A map needs a geometry or geography column. This result has none."))
            )
        } else if let projection = shownProjection {
            if projection.isEmpty {
                UnavailableStateView {
                    Label(String(localized: "Nothing to Draw"), systemImage: "map")
                } description: {
                    Text(projection.diagnostics.emptyReason)
                }
            } else {
                // Old shapes stay up during a rebuild; their row ids index the old rows, so they take no click or selection meanwhile.
                let isCurrent = state.isCurrent(for: projectionKey)
                ResultMapCanvas(
                    projection: projection,
                    projectionToken: state.key.hashValue,
                    selectedRowIDs: isCurrent ? selectedRowIDs : [],
                    fitToken: fitToken,
                    onSelect: { rowID in
                        guard isCurrent else { return }
                        onSelectRow(rowID)
                    }
                )
                .accessibilityIdentifier("result-map")
                .accessibilityLabel(accessibilityLabel(for: projection))
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Building map"))
        }
    }

    // MKMapView reports as an image with no overlay children (measured), so the map is one element and the grid stays the rows.
    private func accessibilityLabel(for projection: ResultMapProjection) -> String {
        let base = String(
            format: String(localized: "Map of %1$d shapes from %2$d rows."),
            projection.diagnostics.drawnShapes,
            projection.diagnostics.drawnRows
        )
        guard !selectedRowIDs.isEmpty else { return base }
        return base + " " + String(
            format: String(localized: "%d rows selected."),
            selectedRowIDs.count
        )
    }

    // MARK: - Projection

    // Kept when built for this key: a connection switch re-runs task(id:) with it unchanged, and a rebuild lost zoom and pan.
    private func rebuild(for expectedKey: ResultMapProjectionKey) async {
        if state.isCurrent(for: expectedKey) { return }
        guard let column = resolved else { return }
        let output = await SpatialResultProjector.shared.project(
            tableRows: tableRows,
            displayIDs: displayIDs,
            column: column
        )
        guard !Task.isCancelled else { return }
        state.commit(output, for: expectedKey)
        fitToken &+= 1
    }
}

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
    let selectedRowIndices: Set<Int>
    let tabId: UUID
    let resultSetId: UUID
    let dataRevision: Int
    let displayRevision: Int
    let onSelectRow: (Int?) -> Void

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
                /// While a rebuild runs the old shapes stay up. The token names the key they were
                /// built for, so the new shapes still read as new, and their row ids index the old
                /// rows, so they take no click and show no selection until the new shapes land.
                let isCurrent = state.isCurrent(for: projectionKey)
                ResultMapCanvas(
                    projection: projection,
                    projectionToken: state.key.hashValue,
                    selectedRowIDs: isCurrent ? selectedRowIDs(in: projection) : [],
                    fitToken: fitToken,
                    onSelect: { rowID in
                        guard isCurrent else { return }
                        select(rowID: rowID)
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

    /// A connection switch re-parents the pane and SwiftUI re-runs `task(id:)` with an unchanged
    /// key; rebuilding then would replace the drawing and lose the user's zoom and pan, so a
    /// projection already built for that key is kept. `task(id:)` cancels the previous task when
    /// the key changes, and a cancelled projection commits nothing. New shapes are fitted once they
    /// are drawn, not when the key changes, so the fit frames them rather than the old ones.
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

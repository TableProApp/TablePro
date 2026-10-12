//
//  ResultMapConfiguration.swift
//  TablePro
//

import Foundation

/// The user's map choices for a tab. Columns are named rather than indexed, so paging, sorting and
/// re-running keep the choice while an edited SELECT list cannot silently draw a different column
/// that happens to land on the same position. A choice that no longer resolves is kept, not erased,
/// so it comes back when the column does.
struct ResultMapConfiguration: Equatable, Hashable, Sendable {
    var geometryColumn: SpatialColumnID?
    var labelColumn: SpatialColumnID?

    init(geometryColumn: SpatialColumnID? = nil, labelColumn: SpatialColumnID? = nil) {
        self.geometryColumn = geometryColumn
        self.labelColumn = labelColumn
    }

    func resolved(in columns: [SpatialColumn]) -> SpatialColumn? {
        columns.first { $0.id == geometryColumn } ?? columns.first
    }
}

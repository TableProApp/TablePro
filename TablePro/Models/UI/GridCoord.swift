import Foundation

/// A cell in the grid's selection.
///
/// `displayColumn` is a display position, not a schema slot: an index into the presented run in
/// `tableColumns` order. `DataGridView+ColumnDisplayOrder` explains why, and is the only place the
/// two spaces are converted.
struct GridCoord: Hashable {
    var row: Int
    var displayColumn: Int
}

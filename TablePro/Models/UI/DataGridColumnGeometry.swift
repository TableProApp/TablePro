//
//  DataGridColumnGeometry.swift
//  TablePro
//

import CoreGraphics
import Foundation

/// Where every data column sits along the grid's x axis.
///
/// The grid draws its cells rather than mounting one view per cell, so `NSTableView` no longer knows
/// where a column is: `frameOfCell(atColumn:row:)` and `column(at:)` can only answer for the single
/// column the data spans. This is what answers instead, for drawing, hit testing, the overlays, the
/// header and accessibility alike.
///
/// Indexed by display position, which is the order the reader sees, and carries each position's data
/// index so a caller needs one lookup rather than two.
///
/// Pure on purpose: the geometry is the part worth testing, and it needs no view to decide.
struct DataGridColumnGeometry: Equatable {
    struct Column: Equatable {
        let dataIndex: Int
        let x: CGFloat
        let width: CGFloat

        var maxX: CGFloat { x + width }
    }

    private(set) var columns: [Column]
    /// The gap drawn after each column, which the document width has to carry.
    let spacing: CGFloat
    /// The width the whole run occupies, which is what the single spanning column is set to.
    let totalWidth: CGFloat

    private let positionByDataIndex: [Int: Int]

    static let empty = DataGridColumnGeometry(dataIndices: [], widths: [], spacing: 0)

    /// - Parameters:
    ///   - dataIndices: the data column each display position shows, in display order.
    ///   - widths: the width of each display position, in the same order.
    init(dataIndices: [Int], widths: [CGFloat], spacing: CGFloat) {
        self.spacing = spacing

        var built: [Column] = []
        built.reserveCapacity(min(dataIndices.count, widths.count))
        var positions: [Int: Int] = [:]
        positions.reserveCapacity(min(dataIndices.count, widths.count))
        var offset: CGFloat = 0

        for position in 0..<min(dataIndices.count, widths.count) {
            let width = max(0, widths[position])
            built.append(Column(dataIndex: dataIndices[position], x: offset, width: width))
            positions[dataIndices[position]] = position
            offset += width + spacing
        }

        self.columns = built
        self.positionByDataIndex = positions
        self.totalWidth = offset
    }

    var count: Int { columns.count }

    var isEmpty: Bool { columns.isEmpty }

    func column(atDisplayPosition position: Int) -> Column? {
        guard columns.indices.contains(position) else { return nil }
        return columns[position]
    }

    func displayPosition(ofDataIndex dataIndex: Int) -> Int? {
        positionByDataIndex[dataIndex]
    }

    func column(withDataIndex dataIndex: Int) -> Column? {
        guard let position = positionByDataIndex[dataIndex] else { return nil }
        return columns[position]
    }

    /// The display position under a point, or `nil` past either end.
    ///
    /// A point in the gap after a column belongs to that column, so a click never falls between two
    /// cells. Binary search, because the reader can be 4,000 columns along and this runs on the
    /// draw and the drag paths.
    func displayPosition(atX x: CGFloat) -> Int? {
        guard !columns.isEmpty, x >= 0, x < totalWidth else { return nil }
        var low = 0
        var high = columns.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if columns[middle].x <= x { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The display positions a horizontal span touches, which is what a draw pass iterates.
    func displayPositions(intersecting span: ClosedRange<CGFloat>) -> Range<Int> {
        guard !columns.isEmpty else { return 0..<0 }
        guard span.upperBound > 0, span.lowerBound < totalWidth else { return 0..<0 }

        let first = displayPosition(atX: max(0, span.lowerBound)) ?? 0
        var last = first
        while last < columns.count, columns[last].x <= span.upperBound {
            last += 1
        }
        return first..<max(last, first + 1)
    }

    /// A cell's rect inside a row, given that row's rect in the table view's coordinate space.
    func rect(atDisplayPosition position: Int, inRow rowRect: CGRect) -> CGRect? {
        guard let column = column(atDisplayPosition: position) else { return nil }
        return CGRect(x: rowRect.minX + column.x, y: rowRect.minY, width: column.width, height: rowRect.height)
    }

    func rect(withDataIndex dataIndex: Int, inRow rowRect: CGRect) -> CGRect? {
        guard let position = positionByDataIndex[dataIndex] else { return nil }
        return rect(atDisplayPosition: position, inRow: rowRect)
    }

    /// A new geometry with one column resized, which is what a header divider drag produces.
    func settingWidth(_ width: CGFloat, atDisplayPosition position: Int) -> DataGridColumnGeometry {
        guard columns.indices.contains(position) else { return self }
        var widths = columns.map(\.width)
        widths[position] = max(0, width)
        return DataGridColumnGeometry(
            dataIndices: columns.map(\.dataIndex),
            widths: widths,
            spacing: spacing
        )
    }

    /// A new geometry with one column moved, which is what a header reorder drag produces.
    func movingColumn(atDisplayPosition source: Int, to destination: Int) -> DataGridColumnGeometry {
        guard columns.indices.contains(source), columns.indices.contains(destination), source != destination else {
            return self
        }
        var dataIndices = columns.map(\.dataIndex)
        var widths = columns.map(\.width)
        let movedIndex = dataIndices.remove(at: source)
        let movedWidth = widths.remove(at: source)
        dataIndices.insert(movedIndex, at: destination)
        widths.insert(movedWidth, at: destination)
        return DataGridColumnGeometry(dataIndices: dataIndices, widths: widths, spacing: spacing)
    }
}

import AppKit
import Foundation
@testable import TablePro
import Testing

struct WorkspaceRailMetricsTests {
    @Test("Rail minimum width follows the system sidebar icon size")
    func widthFollowsRowSizeStyle() {
        #expect(WorkspaceRailMetrics.layout(for: .small).minimumWidth == WorkspaceRailMetrics.small.minimumWidth)
        #expect(WorkspaceRailMetrics.layout(for: .medium).minimumWidth == WorkspaceRailMetrics.medium.minimumWidth)
        #expect(WorkspaceRailMetrics.layout(for: .large).minimumWidth == WorkspaceRailMetrics.large.minimumWidth)
    }

    @Test("An unresolved row size falls back to the medium layout")
    func unresolvedRowSizeUsesMedium() {
        #expect(WorkspaceRailMetrics.layout(for: .default) == WorkspaceRailMetrics.medium)
        #expect(WorkspaceRailMetrics.layout(for: .custom) == WorkspaceRailMetrics.medium)
    }

    @Test("Every minimum leaves room for a label and stays narrow")
    func widthsLeaveRoomForALabel() {
        for layout in [WorkspaceRailMetrics.small, WorkspaceRailMetrics.medium, WorkspaceRailMetrics.large] {
            // The source-list style spends 32pt of the row on insets.
            #expect(layout.minimumWidth - 32 >= 48)
            #expect(layout.minimumWidth <= 120)
        }
    }

    @Test("The maximum width is wider than every minimum")
    func maximumHoldsEveryMinimum() {
        for layout in [WorkspaceRailMetrics.small, WorkspaceRailMetrics.medium, WorkspaceRailMetrics.large] {
            #expect(WorkspaceRailMetrics.maximumWidth > layout.minimumWidth)
        }
    }

    @Test("No label is smaller than the macOS minimum type size")
    func labelsMeetTheMinimumTypeSize() {
        for layout in [WorkspaceRailMetrics.small, WorkspaceRailMetrics.medium, WorkspaceRailMetrics.large] {
            #expect(layout.fontSize >= 10)
        }
    }

    @MainActor
    @Test("A row clears the macOS default control size")
    func rowClearsTheDefaultControlSize() {
        for layout in [WorkspaceRailMetrics.small, WorkspaceRailMetrics.medium, WorkspaceRailMetrics.large] {
            #expect(WorkspaceRailCellView.rowHeight(for: layout) >= 28)
            #expect(layout.minimumWidth >= 28)
        }
    }

    /// The HIG's grouping rule: a glyph and its own label are one item only while the space between
    /// them is clearly smaller than the space between one tile's label and the next tile's glyph.
    @Test("The space between tiles is at least three times the gap inside one")
    func glyphAndLabelReadAsOneGroup() {
        for layout in [WorkspaceRailMetrics.small, WorkspaceRailMetrics.medium, WorkspaceRailMetrics.large] {
            #expect(2 * layout.padding >= 3 * WorkspaceRailMetrics.iconLabelGap)
        }
    }

    @MainActor
    @Test("Larger sidebar icon sizes produce larger minimum rails")
    func layoutsScaleMonotonically() {
        #expect(WorkspaceRailMetrics.small.minimumWidth < WorkspaceRailMetrics.medium.minimumWidth)
        #expect(WorkspaceRailMetrics.medium.minimumWidth < WorkspaceRailMetrics.large.minimumWidth)
        #expect(WorkspaceRailMetrics.small.iconSize < WorkspaceRailMetrics.large.iconSize)
        #expect(
            WorkspaceRailCellView.rowHeight(for: WorkspaceRailMetrics.small)
                < WorkspaceRailCellView.rowHeight(for: WorkspaceRailMetrics.medium)
        )
        #expect(
            WorkspaceRailCellView.rowHeight(for: WorkspaceRailMetrics.medium)
                < WorkspaceRailCellView.rowHeight(for: WorkspaceRailMetrics.large)
        )
    }
}

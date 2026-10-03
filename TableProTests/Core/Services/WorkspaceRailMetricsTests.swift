import AppKit
import Foundation
@testable import TablePro
import Testing

struct WorkspaceRailMetricsTests {
    @Test("Rail width follows the system sidebar icon size")
    func widthFollowsRowSizeStyle() {
        #expect(WorkspaceRailMetrics.layout(for: .small).width == WorkspaceRailMetrics.small.width)
        #expect(WorkspaceRailMetrics.layout(for: .medium).width == WorkspaceRailMetrics.medium.width)
        #expect(WorkspaceRailMetrics.layout(for: .large).width == WorkspaceRailMetrics.large.width)
    }

    @Test("An unresolved row size falls back to the medium layout")
    func unresolvedRowSizeUsesMedium() {
        #expect(WorkspaceRailMetrics.layout(for: .default) == WorkspaceRailMetrics.medium)
        #expect(WorkspaceRailMetrics.layout(for: .custom) == WorkspaceRailMetrics.medium)
    }

    @Test("Every layout leaves room for a label and stays narrow")
    func widthsLeaveRoomForALabel() {
        for layout in [WorkspaceRailMetrics.small, WorkspaceRailMetrics.medium, WorkspaceRailMetrics.large] {
            // The source-list style spends 32pt of the row on insets.
            #expect(layout.width - 32 >= 48)
            #expect(layout.width <= 120)
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
            #expect(layout.width >= 28)
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
    @Test("Larger sidebar icon sizes produce larger rails")
    func layoutsScaleMonotonically() {
        #expect(WorkspaceRailMetrics.small.width < WorkspaceRailMetrics.medium.width)
        #expect(WorkspaceRailMetrics.medium.width < WorkspaceRailMetrics.large.width)
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

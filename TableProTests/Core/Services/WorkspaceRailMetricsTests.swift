import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Workspace rail metrics")
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

    @Test("A row clears the accessibility minimum target size and fits icon plus label")
    func rowFitsItsContent() {
        for layout in [WorkspaceRailMetrics.small, WorkspaceRailMetrics.medium, WorkspaceRailMetrics.large] {
            #expect(layout.rowHeight >= 20)
            #expect(layout.width >= 20)
            #expect(layout.rowHeight >= layout.iconSize + layout.fontSize)
        }
    }

    @Test("Larger sidebar icon sizes produce larger rails")
    func layoutsScaleMonotonically() {
        #expect(WorkspaceRailMetrics.small.width < WorkspaceRailMetrics.medium.width)
        #expect(WorkspaceRailMetrics.medium.width < WorkspaceRailMetrics.large.width)
        #expect(WorkspaceRailMetrics.small.iconSize < WorkspaceRailMetrics.large.iconSize)
    }
}

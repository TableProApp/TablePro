import AppKit
@testable import TablePro
import Testing

struct EditorZoomTests {
    @Test("Zoom moves the editor size one point inside the range")
    func zoomSteps() {
        let typography = TypographySettings(editorFontSize: 13)
        #expect(typography.editorFontSize(zoomedBy: 1) == 14)
        #expect(typography.editorFontSize(zoomedBy: -1) == 12)
    }

    @Test("Zoom has nowhere to go at either end of the range")
    func zoomStopsAtTheLimits() {
        let largest = TypographySettings(editorFontSize: TypographySettings.sizeRange.upperBound)
        let smallest = TypographySettings(editorFontSize: TypographySettings.sizeRange.lowerBound)
        #expect(largest.editorFontSize(zoomedBy: 1) == nil)
        #expect(largest.editorFontSize(zoomedBy: -1) == TypographySettings.sizeRange.upperBound - 1)
        #expect(smallest.editorFontSize(zoomedBy: -1) == nil)
        #expect(smallest.editorFontSize(zoomedBy: 1) == TypographySettings.sizeRange.lowerBound + 1)
    }

    @Test("A stored size outside the range zooms from the size that is drawn")
    func outOfRangeSizeZoomsFromTheDrawnSize() {
        let typography = TypographySettings(editorFontSize: 30)
        #expect(typography.editorFontSize(zoomedBy: 1) == nil)
        #expect(typography.editorFontSize(zoomedBy: -1) == TypographySettings.sizeRange.upperBound - 1)
    }

    @MainActor
    @Test("Zoom In and Zoom Out each dim at their own end of the range")
    func menuItemsFollowTheRange() {
        let zoomIn = #selector(MainSplitViewController.zoomIn(_:))
        let zoomOut = #selector(MainSplitViewController.zoomOut(_:))

        var context = MenuValidationContext()
        context.canZoomOut = true
        #expect(MainSplitViewController.resolvedEnablement(zoomIn, context: context) == false)
        #expect(MainSplitViewController.resolvedEnablement(zoomOut, context: context) == true)

        context.canZoomIn = true
        context.canZoomOut = false
        #expect(MainSplitViewController.resolvedEnablement(zoomIn, context: context) == true)
        #expect(MainSplitViewController.resolvedEnablement(zoomOut, context: context) == false)
    }
}

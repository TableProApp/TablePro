import AppKit
@testable import TablePro
import Testing

struct FontSizeZoomTests {
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

    @Test("The data grid size steps over the same range, apart from the editor's")
    func dataGridSizeSteps() {
        let typography = TypographySettings(editorFontSize: 13, dataGridFontSize: 16)
        #expect(typography.dataGridFontSize(zoomedBy: 1) == 17)
        #expect(typography.dataGridFontSize(zoomedBy: -1) == 15)

        let largest = TypographySettings(editorFontSize: 13, dataGridFontSize: TypographySettings.sizeRange.upperBound)
        let smallest = TypographySettings(editorFontSize: 13, dataGridFontSize: TypographySettings.sizeRange.lowerBound)
        #expect(largest.dataGridFontSize(zoomedBy: 1) == nil)
        #expect(smallest.dataGridFontSize(zoomedBy: -1) == nil)
        #expect(largest.editorFontSize(zoomedBy: 1) == 14)

        let outOfRange = TypographySettings(dataGridFontSize: 30)
        #expect(outOfRange.dataGridFontSize(zoomedBy: -1) == TypographySettings.sizeRange.upperBound - 1)
    }

    @Test("Zoom In and Zoom Out each dim at their own end of each font's range")
    func menuItemsFollowTheRange() {
        let zoomIn = #selector(ZoomCommandResponding.zoomIn(_:))
        let zoomOut = #selector(ZoomCommandResponding.zoomOut(_:))
        let upper = TypographySettings.sizeRange.upperBound
        let lower = TypographySettings.sizeRange.lowerBound

        let middle = TypographySettings(editorFontSize: 13, dataGridFontSize: 13)
        let largeEditor = TypographySettings(editorFontSize: upper, dataGridFontSize: lower)

        #expect(FontSizeZoom.editor.enablement(zoomIn, typography: middle) == true)
        #expect(FontSizeZoom.editor.enablement(zoomOut, typography: middle) == true)
        #expect(FontSizeZoom.editor.enablement(zoomIn, typography: largeEditor) == false)
        #expect(FontSizeZoom.editor.enablement(zoomOut, typography: largeEditor) == true)

        #expect(FontSizeZoom.dataGrid.enablement(zoomIn, typography: middle) == true)
        #expect(FontSizeZoom.dataGrid.enablement(zoomOut, typography: middle) == true)
        #expect(FontSizeZoom.dataGrid.enablement(zoomIn, typography: largeEditor) == true)
        #expect(FontSizeZoom.dataGrid.enablement(zoomOut, typography: largeEditor) == false)

        let other = #selector(MainSplitViewController.clearSelection(_:))
        #expect(FontSizeZoom.editor.enablement(other, typography: middle) == nil)
        #expect(FontSizeZoom.dataGrid.enablement(other, typography: middle) == nil)
    }
}

//
//  DataGridCellViewDoubleClickTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
private final class RecordingAccessoryDelegate: DataGridCellAccessoryDelegate {
    var doubleClicks: [(row: Int, columnIndex: Int)] = []
    var chevronClicks: [(row: Int, columnIndex: Int)] = []
    var fkClicks: [(row: Int, columnIndex: Int, openInNewTab: Bool)] = []

    func dataGridCellDidClickFKArrow(row: Int, columnIndex: Int, openInNewTab: Bool) {
        fkClicks.append((row, columnIndex, openInNewTab))
    }

    func dataGridCellDidClickChevron(row: Int, columnIndex: Int) {
        chevronClicks.append((row, columnIndex))
    }

    func dataGridCellDidDoubleClick(row: Int, columnIndex: Int) {
        doubleClicks.append((row, columnIndex))
    }
}

@Suite("DataGridCellView double-click")
@MainActor
struct DataGridCellViewDoubleClickTests {
    private func makeCell(row: Int, columnIndex: Int, isEditable: Bool = true) -> DataGridCellView {
        let cell = DataGridCellView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        cell.configure(
            kind: .json,
            content: DataGridCellContent(displayText: "{}", rawValue: "{}", placeholder: nil),
            state: DataGridCellState(
                visualState: .empty,
                isFocused: false,
                isEditable: isEditable,
                isLargeDataset: false,
                row: row,
                columnIndex: columnIndex
            ),
            palette: .placeholder
        )
        return cell
    }

    private func mouseDownEvent(clickCount: Int, location: NSPoint = .zero) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }

    @Test("Double-click reports the cell's row and column to the delegate")
    func doubleClickReportsCellPosition() throws {
        let cell = makeCell(row: 3, columnIndex: 2)
        let delegate = RecordingAccessoryDelegate()
        cell.accessoryDelegate = delegate

        cell.mouseDown(with: try mouseDownEvent(clickCount: 2))

        #expect(delegate.doubleClicks.count == 1)
        #expect(delegate.doubleClicks.first?.row == 3)
        #expect(delegate.doubleClicks.first?.columnIndex == 2)
        #expect(delegate.chevronClicks.isEmpty)
        #expect(delegate.fkClicks.isEmpty)
    }

    @Test("Single click does not report a double-click")
    func singleClickDoesNotReportDoubleClick() throws {
        let cell = makeCell(row: 1, columnIndex: 0)
        let delegate = RecordingAccessoryDelegate()
        cell.accessoryDelegate = delegate

        cell.mouseDown(with: try mouseDownEvent(clickCount: 1))

        #expect(delegate.doubleClicks.isEmpty)
    }

    @Test("Current accessory geometry is hittable before a draw pass")
    func currentAccessoryIsHittableBeforeDraw() throws {
        let cell = makeCell(row: 2, columnIndex: 1)
        let delegate = RecordingAccessoryDelegate()
        cell.accessoryDelegate = delegate

        cell.mouseDown(with: try mouseDownEvent(clickCount: 1, location: NSPoint(x: 110, y: 12)))

        #expect(delegate.chevronClicks.count == 1)
    }

    @Test("Reusing a cell cannot retain a stale accessory hit target")
    func reuseCannotRetainStaleAccessoryHitTarget() throws {
        let cell = makeCell(row: 2, columnIndex: 1)
        let delegate = RecordingAccessoryDelegate()
        cell.accessoryDelegate = delegate
        let representation = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: representation)

        cell.configure(
            kind: .json,
            content: DataGridCellContent(displayText: "{}", rawValue: "{}", placeholder: nil),
            state: DataGridCellState(
                visualState: .empty,
                isFocused: false,
                isEditable: false,
                isLargeDataset: false,
                row: 2,
                columnIndex: 1
            ),
            palette: .placeholder
        )
        cell.mouseDown(with: try mouseDownEvent(clickCount: 1, location: NSPoint(x: 110, y: 12)))

        #expect(delegate.chevronClicks.isEmpty)
        #expect(delegate.fkClicks.isEmpty)
    }

    @Test("Accessibility exposes the formatted cell value")
    func accessibilityUsesDisplayText() {
        let cell = DataGridCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let uuid = "af49453b-7f2f-fb58-fcd3-2bd399599fa5"
        cell.configure(
            kind: .blob,
            content: DataGridCellContent(displayText: uuid, rawValue: nil, placeholder: nil),
            state: DataGridCellState(
                visualState: .empty,
                isFocused: false,
                isEditable: false,
                isLargeDataset: false,
                row: 1,
                columnIndex: 2
            ),
            palette: .placeholder
        )

        #expect(cell.accessibilityValue() as? String == uuid)
        #expect(cell.accessibilityLabel()?.contains(uuid) == true)
    }
}

@Suite("DataGridCell accessory layout")
@MainActor
struct DataGridCellAccessoryLayoutTests {
    @Test("Measurement and drawing share one exact geometry contract")
    func sharedGeometryContract() {
        let bounds = NSRect(x: 0, y: 0, width: 120, height: 24)
        func expandedBounds(for accessory: DataGridCellAccessory) -> NSRect {
            NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width + accessory.columnWidthReservation,
                height: bounds.height
            )
        }

        #expect(DataGridCellAccessory.none.measurementPadding == 16)
        #expect(DataGridCellAccessory.chevron.measurementPadding == 32)
        #expect(DataGridCellAccessory.foreignKey.measurementPadding == 36)
        #expect(DataGridCellAccessory.none.availableTextWidth(in: bounds) == 112)
        #expect(DataGridCellAccessory.chevron.availableTextWidth(in: bounds) == 96)
        #expect(DataGridCellAccessory.foreignKey.availableTextWidth(in: bounds) == 92)
        #expect(
            DataGridCellAccessory.chevron.availableTextWidth(
                in: expandedBounds(for: .chevron)
            ) == DataGridCellAccessory.none.availableTextWidth(in: bounds)
        )
        #expect(
            DataGridCellAccessory.foreignKey.availableTextWidth(
                in: expandedBounds(for: .foreignKey)
            ) == DataGridCellAccessory.none.availableTextWidth(in: bounds)
        )
        #expect(DataGridCellAccessory.chevron.frame(in: bounds) == NSRect(x: 104, y: 5, width: 12, height: 14))
        #expect(DataGridCellAccessory.foreignKey.frame(in: bounds) == NSRect(x: 100, y: 4, width: 16, height: 16))
    }

    @Test("Column presentation preserves dropdown, foreign-key, and editability precedence")
    func columnPresentationPrecedence() {
        let explicitDropdown = DataGridColumnPresentation.resolve(
            columnType: .text(rawType: "TEXT"),
            isForeignKey: true,
            isDropdown: true,
            isTypePicker: false,
            isEnumOrSet: false,
            isEditable: true
        )
        let enumForeignKey = DataGridColumnPresentation.resolve(
            columnType: .text(rawType: "TEXT"),
            isForeignKey: true,
            isDropdown: false,
            isTypePicker: false,
            isEnumOrSet: true,
            isEditable: true
        )
        let readOnlyDate = DataGridColumnPresentation.resolve(
            columnType: .date(rawType: "DATE"),
            isForeignKey: false,
            isDropdown: false,
            isTypePicker: false,
            isEnumOrSet: false,
            isEditable: false
        )
        let readOnlyForeignKey = DataGridColumnPresentation.resolve(
            columnType: .text(rawType: "TEXT"),
            isForeignKey: true,
            isDropdown: false,
            isTypePicker: false,
            isEnumOrSet: false,
            isEditable: false
        )

        #expect(explicitDropdown.kind == .dropdown)
        #expect(explicitDropdown.accessory == .chevron)
        #expect(enumForeignKey.kind == .foreignKey)
        #expect(enumForeignKey.accessory == .foreignKey)
        #expect(readOnlyDate.kind == .date)
        #expect(readOnlyDate.accessory == .none)
        #expect(readOnlyForeignKey.kind == .foreignKey)
        #expect(readOnlyForeignKey.accessory == .foreignKey)
    }
}

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
    private func makeCell(row: Int, columnIndex: Int) -> DataGridCellView {
        let cell = DataGridCellView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        cell.configure(
            kind: .json,
            content: DataGridCellContent(displayText: "{}", rawValue: "{}", placeholder: nil),
            state: DataGridCellState(
                visualState: .empty,
                isFocused: false,
                isEditable: true,
                isLargeDataset: false,
                row: row,
                columnIndex: columnIndex
            ),
            palette: .placeholder
        )
        return cell
    }

    private func mouseDownEvent(clickCount: Int) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
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
}
